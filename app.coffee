config = require './config'
OAuth = (require 'oauth').OAuth
byline = require 'byline'
request = require 'request'
iconv = require 'iconv'
liburl = require 'url'
cronJob = (require 'cron').CronJob
RSS = require 'rss'
http = require 'http'

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
  setTimeout (-> do streaming), (Math.pow 2, restartCount) * 1000
  restartCount++

fetchTitle = (url, callback) ->
  req = request.get url: url, encoding: null, (error, response, body) ->
    if not error and 200 <= response.statusCode < 300
      charset = response.headers['content-type']?.match(/charset=([\w\-]+)/)?[1]
      charset = body.toString('binary').match(/charset="?([\w\-]+)"?/)?[1] unless charset?
      if charset?
        try
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
  streamUrl = unless config.test then 'https://userstream.twitter.com/1.1/user.json?replies=all' else 'https://userstream.twitter.com/1.1/statuses/sample.json'
  req = oauth.get streamUrl, config.accessToken, config.accessTokenSecret
  req.on 'response', (res) ->
    res.setEncoding 'utf8'
    ls = byline.createLineStream res

    ls.on 'data', (line) ->
      if line isnt ''
        tweet = JSON.parse line
        if tweet.entities?.urls.length > 0
          for url in tweet.entities.urls
            parsedUrl = liburl.parse url.expanded_url
            if tweet.user.screen_name is config.myName or (config.skip.indexOf parsedUrl.hostname) isnt -1 then continue
            if (config.expand.indexOf parsedUrl.hostname) isnt -1
              expandUrl url.expanded_url, (url) ->
                pushUrl url, tweet.user.screen_name, tweet.text, tweet.created_at
            else
                pushUrl url.expanded_url, tweet.user.screen_name, tweet.text, tweet.created_at

    ls.on 'end', ->
      do restart
      console.log "restartCount: #{restartCount}"

  do req.end

do streaming

feed = new RSS {
  title: 'feedline'
  }

job = new cronJob config.cron, ->
  for k, v of urls
    continue unless v.title
    description = if v.description then "<p>#{v.description}</p><ul>" else '<ul>'
    for name, i in v.name
      description += "<li><a href=\"https://twitter.com/#{name}\">@#{name}</a>: #{v.comment[i]}</li>"
    feed.item {
      title: v.title
      description: description + '</ul>'
      url: k
      date: v.date[0]
    }
    delete urls[k]
  feed.items = feed.items.reverse()
  xml = feed.xml()
  feed.items = feed.items.reverse()
do job.start

http.createServer (req, res) ->
  res.writeHead 200, 'Content-Type': 'application/xml'
  res.end xml
.listen config.port
