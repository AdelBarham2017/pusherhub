--------------------
-- PusherHub
-- opensource websocket messaging for CoronaSDK and Pusher.com
--
-- Authors: Jack9
--
-- License: WTFPL
--------------------
local socket = require("socket")
local mime = require("mime")
local crypto = require("crypto")

local self = {
    socket_id = nil,
    readyCallback = nil,
    disconnectCallback = nil,
    pushererrorCallback = nil,
    server = nil,
    port = nil,
    headers = '',
    key = nil,
    secret = nil,
    app_id = nil,
    sock = nil,
    buffer = '',
    channels = {},
    readyState = 3,
    --0 (connecting), 1 (open), 2 (closing), and 3 (closed).
}

self.lpad = function(str, len, char)
    str = tostring(str)
    if char == nil then
        char = ' '
    end
    return string.rep(char, len - #str)..str
end
self.tobits = function(num)
    -- returns a table of bits, least significant first.
    local t={} -- will contain the bits
    while num>0 do
        rest=math.fmod(num,2)
        t[#t+1]=rest
        num=(num-rest)/2
    end
    return string.reverse(table.concat(t))
end
self.handleBytes = function(byes)
    --print("some binary msg",byes)
    local chrs = {}
    local chr
    for i=1,string.len(byes) do
        chr = byes:byte(i)
        chrs[#chrs+1] = chr
    end
    --print(util.xmp(chrs))
    return chrs
end
self.makeFrame = function(str,pong)
    if str == nil then
        str = ''
    end
    -- UGLY HARD PART - Assemble Websocket Frame Header
    -- see http://tools.ietf.org/html/rfc6455#section-5 (5.2)
    local bitGroups = {}
    local binStr = "1" -- FIN, why not? 1
    binStr = binStr.."000" -- RSV1,RSV2,RESV3,
                           -- the 'Sec-WebSocket-Extensions: x-webkit-deflate-frame' + RSV1 doesn't have an effect
    if not pong then
        binStr = binStr.."0010" -- %x1 denotes a text frame (I guess this means 0001) - confirmed
    else
        binStr = binStr.."1001" -- %xA denotes a pong frame
    end
    bitGroups[#bitGroups+1] = binStr -- we dump the value and have a byte

    binStr = "0" -- Not using a mask and starting over on the binStr
    local strLen = string.len(str) -- message length in bytes
    --print("strLen",strLen)
    local pad = 7 -- Spec says default of 7
    -- The wording is a little confusing. spec says ... determine how many bits you need BEFORE
    -- assembling a text/binary/continuation message
    -- If our strLen is over 125, we have to IGNORE the initial 7 because they become a placeholder value.
    -- If strLen is 126-65536 we can use 16 bits and leave the initial 7 at a placeholder of 126
    -- If strLen is more than 65536, we leave the initial 7 at 127 and use 64 bits
    -- use those NEW bits to represent the message size.
    if strLen > 125 then
        --print("we're over 125")
        if strLen <= 65536 then
            binStr = binStr.."1111110"
            -- 16 bit time
            pad = 16
        else
            --print("we're over 65536?")
            binStr = binStr.."1111111"
            -- 64 bit time!
            pad = 64
            -- TODO: Construct continuation frames for when data is too large?! Don't know what limit pusher has.
        end
    end
    --print(strLen,self.tobits(strLen))
    binStr = binStr..self.lpad(self.tobits(strLen),pad,"0") -- 7 or 7+16 or 7+64 bits to represent message byte length
    --print(binStr)

    local s = 1
    local e = 8
    while e < pad+9 do
        bitGroups[#bitGroups+1] = string.sub(binStr,s,e) -- we dump the value and have another byte
        s = s+8
        e = e+8
    end

    -- There are many ways to go from here. I chose a way that works. Can probably be improved.
    local ret = ''
    for i=1,#bitGroups do
        -- Now that we've assembled a delicate set of bits, move to bytes
        ret = ret..string.char(tonumber(bitGroups[i],2))
    end
    --print(table.concat(bitGroups),string.len(str)) -- use http://home.paulschou.net/tools/xlate/
    -- Leading bytes are the header for the frame. Ta-da
    return ret..str
end
self.websocketresponse6 = function(key)
    -- This string is hardcoded per websocket specification
    local magic = key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return (mime.b64(crypto.digest(crypto.sha1, magic, true)))
end
self.new = function (params) -- constructor method
    params = params or {}
    params.port = params.port or 80
    if not params.server or not params.key or not params.secret or not params.app_id then
        print("PusherHub requires server, key, secret, app_id, readyCallback function and defaults to port 80")
        self.disconnect()
        return self
    end
    -- Headers are legitimate, since Chrome uses them in pusher.com's test page
    params.headers = params.headers or {
        'GET /app/'..params.key..'?protocol=6&client=lua&version=1.1&flash=false HTTP/1.1',
        'Host: '..params.server,
        'Sec-WebSocket-Key: '..self.websocketresponse6(params.app_id), -- anything is fine, might as well use the app_id for something
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Version: 13',
        --'Pragma: no-cache',
        --'Authentication: Basic '..(mime.b64(params.key..":"..params.secret)),
        'Origin: http://jsonur.com',
        --'User-Agent: Mozilla/5.0 (Windows NT 5.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/27.0.1453.116 Safari/537.36', -- headers based on Chrome
        --'Sec-WebSocket-Extensions: x-webkit-deflate-frame',
        --'Cache-Control: no-cache',
    }
    self.readyCallback = params.readyCallback or function() end
    self.disconnectCallback = params.disconnectCallback or function() end
    self.pushererrorCallback = params.pushererrorCallback or function() self.disconnect(); end
    self.server = params.server
    self.port = params.port
    for i=1,#params.headers do
        self.headers = self.headers..params.headers[i].."\n"
    end
    self.headers = self.headers.."\n"
    self.key = params.key
    self.secret = params.secret
    self.app_id = params.app_id
    self.sock = socket.tcp()
    if( self.sock == "nil" or self.sock == nil) then
        print("can't get a valid tcp socket")
        self.disconnect()
        return self
    end
    self.sock:settimeout(1) -- minimum 1 !!!
    self.sock:setoption( 'tcp-nodelay', true ) -- If I want to send 1 byte, I should be able to!
    --self.sock:setoption( 'keepalive', true ) -- No need. We have ping/pong from the spec
    self.readyState = 0
    local _,erro = self.sock:connect(self.server,  self.port)
    if erro then
        print("error connecting")
        self.disconnect()
        return self
    end
    -- Check if headers are good
    --print(self.headers)
    local bytesSent = self.sock:send(self.headers)
    --print("sent bytes:",bytesSent)
    self.origParams = params
    Runtime:addEventListener('enterFrame', self)
    return self
end
self.subscribe = function(params)
    local string_to_sign, proper, strange
    params.channel = params.channel or 'test_channel'
    params.private = false
    params.presence = false
    if string.sub(params.channel,1,8) == "private-" then
        params.private = true
    end
    if params.channel_data and string.sub(params.channel,1,9) == "presence-" then
        params.presence = true
    end
    self.channels[params.channel] = { -- this could get ugly if you resubscribe with new events
        events = params.bindings
    }
    local msg = {
        event = "pusher:subscribe",
        data = {
            channel = params.channel,
        },
    }
    if params.private or params.presence then
        --pusher.com docs say HMAC::SHA256.hexdigest(secret, string_to_sign),
        string_to_sign = self.socket_id..":"..params.channel
        -- in a presence channel... you need the channel_data appended - double encoded and stripped of outer quotes...and slashes?
        if params.presence then
            proper = json.encode(json.encode(params.channel_data))
            strange = string.sub(proper,2,string.len(proper)-1) -- wtf!
            strange = string.gsub(strange,"\\","") -- wtf x 2!
            --print(strange)
            string_to_sign = self.socket_id..":"..params.channel..":"..strange
        end
        msg.data.auth = self.key..":"..crypto.hmac( crypto.sha256, string_to_sign, self.secret )
        msg.data.channel_data = json.encode(params.channel_data)
    end
    msg = json.encode(msg)
    --print(msg)
    self.publish(msg)
    return true
end
self.unsubscribe = function(chan)
    -- Wipe out bindings, you won't get to see your own parting
    for i=1,#self.channels[chan]["events"] do
        self.channels[chan]["events"][i] = nil
    end
    self.channels[chan] = nil
    local msg = {
        ["event"] = "pusher:unsubscribe",
        ["data"] = {
            ["channel"] = chan,
        },
    }
    msg = json.encode(msg)
    self.publish(msg)
end
-- Untested
self.reconnect = function()
    print("PusherHub: attempt to reconnect...")
    self = self.new(self.origParams)
    Runtime:addEventListener('enterFrame', self)
    return self
end
self.disconnect = function()
    self.readyState = 2
    print("websocket closing")
    Runtime:removeEventListener('enterFrame',self)
    if self.socket ~= nil then
        self.socket:close()
    end
    self.socket_id = nil
    self.readyState = 3
    self.disconnectCallback()
end
self.publish = function(msg)
    print("publishing",msg)
    local num_byes = self.sock:send(self.makeFrame(msg))
    --print("bytes published",num_byes)
    return true
end
self.enterFrame = function(evt)
    local msg, chr, str, headerbytesend
    local chrs = {}
    local got_something_new = false
    local skt, e, p, b
    local input,output = socket.select({ self.sock },nil, 0) -- this is a way not to block runtime while reading socket. zero timeout does the trick
    for i,v in ipairs(input) do  -------------
        while  true  do
            skt, e, p = v:receive()

            -- MOST USEFUL DEBUG is this and print(util.xmp(chrs)) in handleBytes
            print("reading",skt,e,p) -- the "timeout" in the console is from "e" which is ok

            -- if there is a p (msg) we don't read the e
            -- except, if p is "closed" it has no header frame. Specific to pusher.com Strange.
            if p == "closed" then
                p = ''
                e = tostring(e).."closed"
            end
            if (p ~= nil and p ~= '') then
                --print("p",p)
                got_something_new = true -- probably a good msg
                self.buffer = self.buffer..p
                break
            elseif (e ~= nil and e ~= '') then
                --print("e",e) -- generally a non-nil error code is fatal
                -- We are being told, this is closed. So we're done.
                print("read an error")
                self.disconnect()
                break
            elseif (skt) then
                --print("skt",skt) -- raw text info, like streamed headers
            end
        end -- /while-do
        -- now, checking if a message is present in buffer...
        if got_something_new then  --  this is for a case of several messages stocker in the buffer
            --print("somethingnew",self.buffer)
            headerbytesend = string.len(self.buffer)
            -- Standard message for pusher.com (some bytes header, then json)
            b,_ = string.find(self.buffer, "{")
            if b ~= nil then
                msg = string.sub(self.buffer,b)-- have to remember to strip off those frame header bytes!
                --print("removed header",msg)
                msg = json.decode(msg)
                if msg ~= nil then -- valid json
                    -- Startup Connection parsing, specific to pusher.com
                    if msg.event == "pusher:connection_established" then
                        msg = json.decode(msg["data"])
                        self.socket_id = msg.socket_id
                        self.readyState = 1
                        self.readyCallback() -- should call subscribe, I hope! If not, whatever.

                    -- This is a pusher protocol error. Not fatal. Default behavior is disconnect()
                    elseif msg.event == "pusher:error" then
                        msg.data = json.decode(msg["data"])
                        self.pushererrorCallback(msg)
                        --print("Nonfatal Err:",msg.data.message)

                    -- This is the catch-all binding code. If you have a handler, it gets called.
                    elseif self.channels[msg.channel] ~= nil and type(self.channels[msg.channel]["events"][msg.event]) == "function" then -- typical msg
                        --print("standard event")
                        msg.data = json.decode(msg["data"])
                        self.channels[msg.channel]["events"][msg.event](msg)
                    end
                    headerbytesend = b-1
                end
                b = nil
                msg = nil
            end
            -- This is usually 129 (text frame header) + another char telling you the message size in bytes
            -- since b -> end of buffer is the json message
            chrs = self.handleBytes(string.sub(self.buffer,1,headerbytesend))
            self.buffer = ''

            -- 136 is 0x8 close
            if chrs[1] == 136 then -- this is a close message
                print("heard close message")
                self.disconnect()
            end

            -- 137 is 0x9 ping
            if chrs[1] == 137 then -- this is a ping, we can ignore chrs[2] which is usually 0
                -- In response we will make a 0xA or [138 0]
                print("sending pong!")
                local byes = self.sock:send(self.makeFrame(msg,true)) -- per spec, we have to send back anything that came with the ping
                --print("bytes sent:",byes)
            end

            -- TODO: Implement a timeout if no pongpong in 30s
            -- 138 is their pong to our pong, pongpong!
            if chrs[1] == 138 then -- this is a pongpong response
                print("got pongpong")
            end

            got_something_new = false
        end
    end
end -- /enterFrame
return self


--[[
-- Example Usage 
    print("connecting to chat server...")
    mychathub = nil -- global
    mychathub = pusherhub.new({ 
        app_id = '12345', -- Example
        key = '278d425bdf160c739803', -- Example http://pusher.com/docs/auth_signatures
        secret = '7ad3773142a6692b25b8', -- Example http://pusher.com/docs/auth_signatures
        server = "ws.pusherapp.com",
        port = 80,
        disconnectCallback = function()
            scene:dispatchEvent("chatDisconnect",scene)
        end,
        pushererrorCallback = function()
            scene:dispatchEvent("chatError", scene)
            scene:dispatchEvent("chatDisconnect",scene)
        end,
        readyCallback = function()
            print("Connected to chat server.")
            print("Attempting to join Gen Chat...")
            mychathub.subscribe({
                channel = "test_channel",
                bindings = {
                    ["client-message"] = function(msg1)
                        print("test client-message",msg1)
                    end,
                    ["pusher_internal:subscription_succeeded"] = function(msg2) -- Msg2 is a table
                        print("test pusher_internal:subscription_succeeded",msg2.event) 
                        print("Joined Gen Chat.")
                    end
                }
            })
        end
    })
]]--
