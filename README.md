pusherhub
=========

Lua Implementation of RFC 6445 and integrated with Pusher.com

Caveats: Using a sandbox (free) account, you don't want to try a presence- channel. 
You will get a pusher protocol error from trying to create a presence- channel.
You cannot use a secure connection in a sandbox (free) account. 
The pusher docs are... hard to get through http://pusher.com/docs because the API/Websocket information is mixed together. RFC I used was http://tools.ietf.org/html/rfc6455#section-5.5.3
