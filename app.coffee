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
charsetDetector = require 'node-icu-charset-detector'

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
  buffer = new Buffer 0
  req = request.get url, timeout: 10 * 1000, headers: {'User-Agent': 'feedline'}
  req.on 'error', (err) ->
    log.info err.stack
  req.on 'response', (res) ->
    if res.statusCode is 200 and res.headers['content-type']?.match /text\/html/
      charset = res.headers['content-type'].match(/charset=([\w\-]+)/)?[1]
      res.on 'data', (chunk) ->
        buffer = Buffer.concat [buffer, chunk]
      res.on 'end', ->
        if not (charset in ['utf-8', 'shift_jis', 'euc-jp'])
          charset = charsetDetector.detectCharset(buffer)
          if charset.confidence < 60
            charset = 'UTF-8'
          else
            charset = charset.toString()
        if charset.toUpperCase() is 'UTF-8'
          body = buffer.toString()
        else
          converter = new iconv.Iconv charset, 'UTF-8//IGNORE'
          body = converter.convert(buffer).toString()
        title = body.match(/<title>(.*?)<\/title>/i)?[1]
        description = body.match(/meta name="description" content="(.*?)"/im)?[1]
        callback title, (if description?.length > 500 then description.slice(0, 500) + '\u2026' else description), url
    else
      do req.abort
      callback null, null, url
  do req.end

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
          if (config.ignoreName.test tweet.user.screen_name) or (parsedUrl.hostname in config.skip) then continue
          if parsedUrl.hostname in config.expand
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
