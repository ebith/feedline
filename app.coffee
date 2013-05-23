config = require './config'
OAuth = (require 'oauth').OAuth
byline = require 'byline'
request = require 'request'
iconv = require 'iconv'
cheerio = require 'cheerio'
liburl = require 'url'
cronJob = (require 'cron').CronJob
RSS = require 'rss'
http = require 'http'

restartCount = 0
urls = []
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

pushUrl = (url, name, comment, date) ->
  urls.push {
    url: url
    name: name
    comment: comment
    date: date
  }

expandUrl = (url, callback) ->
  request.head {url: url, followAllRedirects: true}, (err, res, body) ->
    if not err and 200 <= res.statusCode < 300
      callback res.request.href
    else
      callback url

streaming = ->
  JP = new RegExp "[\\u4e00-\\u9fa0\\u30A1-\\u30F6\\u30FC\\u3042-\\u3093\\u3001\\u3002\\uFF01\\uFF1F]"
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
            if tweet.user.screen_name is config.myName then continue
            if (config.skip.indexOf parsedUrl.hostname) isnt -1 then continue
            (if not JP.test tweet.text then continue) if config.test
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

fetchTitle = (url, callback) ->
  request.get url: url, encoding: null, (error, response, body) ->
    if not error and 200 <= response.statusCode < 300
      charset = response.headers['content-type']?.match(/charset=([\w\-]+)/)?[1]
      charset = body.toString('binary').match(/charset="?([\w\-]+)"?/)?[1] unless charset?
      if charset?
        try
          converter = new iconv.Iconv(charset, 'UTF-8//IGNORE')
          body = converter.convert(body)
      $ = cheerio.load body.toString(), { lowerCaseTags: true }
      callback $('title').text(), $('meta[name=description]').attr("content"), url
    else
      callback null, null, url

makeSummary = (urls, callback) ->
  tmp = {}
  for v in urls
    tmp[v.url] = {
      name: []
      comment: []
      date: []
    }
  for v, i in urls
    tmp[v.url].name.push v.name
    tmp[v.url].comment.push v.comment
    tmp[v.url].date.push v.date
  l = (Object.keys tmp).length
  i = 1
  for k, v of tmp
    fetchTitle k, (title, description, url) ->
      tmp[url].title = title
      tmp[url].description = description
      if i < l
        i++
      else
        urls.splice(0, l)
        callback tmp

makeFeed = (urls, callback) ->
  makeSummary urls, (data) ->
    for k, v of data
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
    do callback

job = new cronJob config.cron, ->
  makeFeed urls, ->
    feed.items = feed.items.reverse()
    xml = feed.xml()
    feed.items = feed.items.reverse()
do job.start

http.createServer (req, res) ->
  res.writeHead 200, 'Content-Type': 'application/xml'
  res.end xml
.listen config.port
