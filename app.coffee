OAuth = (require 'oauth').OAuth
es = require 'event-stream'
request = require 'request'
iconv = require 'iconv'
liburl = require 'url'
cronJob = (require 'cron').CronJob
RSS = require 'rss'
http = require 'http'
ent = require 'ent'
fs = require 'fs'
log = new (require 'log') 'info'

config = require './config'
configMtime = 0
loadConfig = (lastTime=0) ->
  configPath = './config'
  configMtime = (fs.statSync require.resolve configPath).mtime.getTime()
  if lastTime < configMtime
    delete require.cache[require.resolve configPath]
    config = require configPath

restartCount = 0
urls = {}
xml = ''

oauth = new OAuth 'http://twitter.com/oauth/request_token',
  'http://twitter.com/oauth/access_token',
  config.consumerKey,
  config.consumerSecret,
  '1.0A',
  null,
  'HMAC-SHA1'

restart = ->
  setTimeout (-> do streaming), (Math.pow restartCount, 2) * 1000
  restartCount++

fetchTitle = (url, callback) ->
  req = request.get url: url, encoding: null, (error, response, body) ->
    if not error and 200 <= response.statusCode < 300 and response.headers['content-type']?.match(/text\/html/)
      charset = response.headers['content-type']?.match(/charset=([\w\-]+)/)?[1]
      charset = body.toString('binary').match(/charset="?([\w\-]+)"?/i)?[1] unless charset
      charset = 'Shift_JIS' unless charset
      switch charset.toLowerCase()
        when 'x-sjis'
          charset = 'Shift_JIS'
      try # 未知のcharsetで転ける
        converter = new iconv.Iconv(charset, 'UTF-8//IGNORE')
        body = converter.convert(body)
      body = body.toString()
      title = body.match(/<title>(.*?)<\/title>/i)?[1]
      description = body.match(/meta name="description" content="(.*?)"/im)?[1]
      callback title, (if description?.length > 500 then description.slice(0, 500) + '...' else description), url
    else
      callback null, null, url

pushUrl = (url, name, comment, date) ->
  unless urls[url]
    urls[url] = {
      name: []
      comment: []
      date: []
    }
    fetchTitle url, (title, description, url) ->
      urls[url].title = title
      urls[url].description = description
  urls[url].name.push name
  urls[url].comment.push comment
  urls[url].date.push date

expandUrl = (url, callback) ->
  request.head {url: url, followAllRedirects: true}, (err, res, body) ->
    if not err and 200 <= res.statusCode < 300
      callback res.request.href
    else
      callback url

streaming = ->
  streamUrl = unless config.test then 'https://userstream.twitter.com/1.1/user.json?replies=all' else 'https://stream.twitter.com/1.1/statuses/sample.json'
  req = oauth.get streamUrl, config.accessToken, config.accessTokenSecret
  req.on 'response', (res) ->
    res.setEncoding 'utf8'
    ls = res.pipe es.split '\n'

    ls.on 'data', (line) ->
      return unless line.length > 1
      tweet = JSON.parse line
      if tweet.entities?.urls.length > 0
        for url in tweet.entities.urls
          parsedUrl = liburl.parse url.expanded_url
          if (config.ignoreName.test tweet.user.screen_name) or (config.skip.indexOf parsedUrl.hostname) isnt -1 then continue
          if (config.expand.indexOf parsedUrl.hostname) isnt -1
            expandUrl url.expanded_url, (url) ->
              pushUrl url, tweet.user.screen_name, tweet.text, tweet.created_at
          else
            pushUrl url.expanded_url, tweet.user.screen_name, tweet.text, tweet.created_at

    ls.on 'end', ->
      do restart
      log.info "restartCount: #{restartCount}"

  do req.end

do streaming

feed = new RSS {
  title: 'feedline'
  }

job = new cronJob config.cron, ->
  loadConfig configMtime
  for k, v of urls
    continue unless v.title
    description = if v.description then "<p>#{v.description}</p><ul>" else '<ul>'
    for name, i in v.name
      description += "<li><a href=\"https://twitter.com/#{name}\">@#{name}</a>: #{v.comment[i]}</li>"
    feed.items.unshift {
      title: ent.decode v.title
      description: ent.decode description + '</ul>'
      url: k
      date: v.date[0]
      categories: []
      enclosure: false
    }
    delete urls[k]
  feed.items = feed.items.slice 0, 1000
  xml = feed.xml()
do job.start

http.createServer (req, res) ->
  res.writeHead 200, 'Content-Type': 'application/xml'
  res.end xml
.listen config.port
