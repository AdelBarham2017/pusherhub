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
local json = require("json")

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
    readyState = 3, --0 (connecting), 1 (open), 2 (closing), and 3 (closed).
    params = nil,
}

self.lpad = function(str, len, char)
    str = tostring(str)
    if char == nil then
        char = ' '
    end
    return string.rep(char, len - #str)..str
end
-- Converts a string of bits into a decimal number.
self.bytesToDec = function(str)
    local bits = ''
    for i=1,string.len(str) do
        bits = bits..self.toBits(string.byte(string.sub(str,i,i)))
    end
    return tonumber(bits,2)
end
self.toBits = function(num)
    -- returns a table of bits, least significant first.
    local t={} -- will contain the bits
    local rest = nil
    while num>0 do
        rest=math.fmod(num,2)
        t[#t+1]=rest
        num=(num-rest)/2
    end
    return string.reverse(table.concat(t))
end

-- This reads the first 2 bytes from messages that are incoming - see enterFrame
self.parseHeader = function(headerbytes)
    local fbyte = string.sub(headerbytes,1,1) -- first
    --print("debug fbyte",fbyte) -- usually unreadable
    local fbits = self.toBits(string.byte(fbyte))
    --print("debug fbits",fbits) -- will be 8 bits
    local opcode = tonumber("0000"..string.sub(fbits,5),2) -- this is how you determine opcode

    local sbyte = string.sub(headerbytes,2) -- second, this strips the mask bit off
    --print("debug sbyte",sbyte) -- may be unreadable byte
    local sbits = self.toBits(string.byte(sbyte))
    --print("debug sbits",sbits) -- will be 7 bits
    local payloadlen = tonumber("0"..sbits,2) -- this pads the missing mask bit on
    
    -- Example, this works out to be 84 bytes:
    --{"event":"pusher:connection_established","data":"{\"socket_id\":\"46276.4985621\"}"}
    --so payloadlen = 84
    
    --print("debug opcode:",opcode)
    --print("debug payloadlen:",payloadlen)
    return opcode, payloadlen
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
            --print("less than max, using 16 bit")
            binStr = binStr.."1111110"
            -- 16 bit time
            pad = 16
        else
            --print("over max of 65536, using 64 bit")
            binStr = binStr.."1111111"
            -- 64 bit time!
            pad = 64
            -- TODO: Construct continuation frames for when data is too large?! Don't know what limit pusher has.
        end
    end
    --print("debug strLen is",strLen,self.toBits(strLen))
    binStr = binStr..self.lpad(self.toBits(strLen),pad,"0") -- 7 or 7+16 or 7+64 bits to represent message byte length
    --print("debug binStr",binStr, "pad:", pad)

    -- This chops the binStr into 8 bit groups, called bitgroups (bytes)
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
    --print("debug final size",table.concat(bitGroups),str,string.len(str)) -- use http://home.paulschou.net/tools/xlate/
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
    self.params = params
    params.port = params.port or 80
    if not params.server or not params.key or not params.secret or not params.app_id then
        print("PusherHub requires server, key, secret, app_id, readyCallback function and defaults to port 80")
        self.disconnect()
        return self
    end
    -- Headers are legitimate, since Chrome uses them in pusher.com's test page
    params.headers = params.headers or {
        'GET /app/'..params.key..'?protocol=6&client=lua&version=2.0&flash=false HTTP/1.1',
        'Host: '..params.server,
        'Sec-WebSocket-Key: '..self.websocketresponse6(params.app_id), -- anything is fine, might as well use the app_id for something
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Version: 13',
        --'Pragma: no-cache',
        --'Authentication: Basic '..(mime.b64(params.key..":"..params.secret)),
        'Origin: http://somedomain.com',
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
    --print("channel data was",params.channel_data)
    if type(params.channel_data) ~= 'table' then
        params.channel_data = {}
    end
    params.private = false
    params.presence = false
    if string.sub(params.channel,1,8) == "private-" then
        params.private = true
    end
    if string.sub(params.channel,1,9) == "presence-" then
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
        --string_to_sign = self.socket_id..":"..params.channel
        -- in a presence channel... you need the channel_data appended - double encoded and stripped of outer quotes...and slashes?
        proper = json.encode(json.encode(params.channel_data))
        strange = string.sub(proper,2,string.len(proper)-1) -- wtf!
        strange = string.gsub(strange,"\\","") -- wtf x 2!
        --print(strange)
        string_to_sign = self.socket_id..":"..params.channel..":"..strange
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

-- The receiver loop
self.enterFrame = function(evt)
    local msg, chr, str, opcode, payloadlen, payloadstart, payloadend
    local chrs = {}
    local got_something_new = false
    local skt, e, p, b
    local input,output = socket.select({ self.sock },nil, 0) -- this is a way not to block runtime while reading socket. zero timeout does the trick
    for i,v in ipairs(input) do  -------------
        while  true  do
            skt, e, p = v:receive()

            -- MOST USEFUL DEBUG is this and print(util.xmp(chrs)) in handleBytes
            --print("reading",skt,e,p) -- the "timeout" in the console is from "e" which is ok

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
        while got_something_new do  --  this is for a case of several messages stocked in the buffer
            --print("debug buffer:"..string.len(self.buffer),self.buffer)
            -- Standard message for pusher.com (some bytes header, then json)

            -- first 2 bytes tell us a great deal.
            -- specificially, the payload length (or indicator that it's [126] a big int or [127] a REALLY big int)
            opcode, payloadlen = self.parseHeader(string.sub(self.buffer,1,2)) -- returns a tuple

            payloadstart = 3 -- bytes. no more metadata. the start byte number is offset by 2 bytes of required metadata
            payloadend = payloadlen+2 -- bytes. the end byte number is offset by 2 bytes of required metadata
            --[[print("debug intial look:",util.xmp({
                pstart=payloadstart,
                pend=payloadend
            }))]]--

            if payloadlen == 126 then -- we have 2 more bytes of metadata...beyond the required 2
                -- if payloadlen == 126, that means the first 2 bytes were maxed out in size
                -- we have to strip out those 2 other (probably) unreadable bytes that follow and calc the full length
                
                -- This is the byte for the start of the actual message (not metadata)
                payloadstart = 5 -- starts on 5th byte.
                                 -- first 4 bytes of message are header data.
                                 -- 2 required meta, 2 payload length description (16 bits)

                -- bytesToDec converts the bits in the included bytes, to a decimal number
                payloadend = self.bytesToDec(string.sub(self.buffer,3,4)) -- this is inclusive, 3rd and 4th bytes
                --print("debug 126 mode, payloadend =", payloadend)
                
                -- represents the number of payload bytes
                payloadend = payloadend+4 -- bytes. length of message + 4 metadata
            elseif payloadlen == 127 then -- we have 8 more bytes of metadata
                -- if payloadlen == 127, that means the first 2 bytes were maxed out in size
                -- we have to strip out those 8 other (probably) unreadable bytes that follow and calc the full length
                
                -- This is the byte for the start of the actual message (not metadata)
                payloadstart = 11 -- starts on 11th byte.
                                  -- first 10 bytes of message are header data.
                                  -- 2 required meta, 8 payload length description (64 bits)

                -- bytesToDec converts the bits in the included bytes, to a decimal number
                payloadend = self.bytesToDec(string.sub(self.buffer,3,10)) -- this is inclusive, 3rd through 10th bytes
                --print("debug 127 mode, payloadend =", payloadend)
                
                -- represents the number of payload bytes
                payloadend = payloadend+10 -- bytes. payload + 10 bytes of metadata
            end

            -- this needs to be correct so that we're sure of how long the message is
            -- most clients, like firefox or chrome, cut off after 32k as of 2012 and probably till today
            msg = string.sub(self.buffer, payloadstart, payloadend)
            
            --print("debug opcode", opcode)
            --print("debug msg",msg)

            msg = json.decode(msg)
            if msg == nil then
              break
            end
                
            -- Startup Connection parsing, specific to pusher.com
            if msg.event == "pusher:connection_established" then
                if type(msg.data) == "string" then
                 msg.data = json.decode(msg.data)
                end 
                self.socket_id = msg.data.socket_id
                self.readyState = 1
                self.readyCallback(self.params) -- should call subscribe, I hope! If not, whatever.

            -- This is a pusher protocol error. Not fatal. Default behavior is disconnect()
            elseif msg.event == "pusher:error" then
                if type(msg.data) == "string" then
                 msg.data = json.decode(msg.data)
                end 
                self.pushererrorCallback(msg.data)
                --print("Nonfatal Err:",msg.data.message)

            -- This is the catch-all binding code. If you have a handler, it gets called.
            elseif self.channels[msg.channel] ~= nil and type(self.channels[msg.channel]["events"][msg.event]) == "function" then -- typical msg
                --print("standard event")
                if type(msg.data) == "string" then
                 msg.data = json.decode(msg.data)
                end 
                self.channels[msg.channel]["events"][msg.event](msg)
            end
            
            if opcode == 0 then
                -- TODO: continuation support
                print("continuation frames are not yet supported!")
            end
            if opcode == 1 then -- typical text frame
                -- noop
            end
            if opcode == 2 then
                -- Pusher does not support binary frames
                print("bad opcode, ignoring")
            end
            if opcode == 8 then -- this is a close message via opcode
                print("heard close message")
                self.disconnect()
            end
            if opcode == 9 then -- this is a ping
                -- In response we will make a 0xA or [138 0]
                print("sending pong!")
                -- TODO: per spec, we have to send back anything that came with the ping
                local byes = self.sock:send(self.makeFrame(msg,true))
                --print("bytes sent:",byes)
            end
            -- 0xA is their pong to our pong, pongpong!
            if opcode == 10 then -- this is a pongpong response
                -- TODO: Implement a timeout if no pongpong in 30s
                print("got pongpong")
            end

            self.buffer = string.sub(self.buffer,payloadstart+payloadend)
            got_something_new = self.buffer ~= '' -- if not empty, got something new
        end
    end
end -- /enterFrame
return self
--[[
--Handy for dumping table data to console
util = {
    xmp = function(o, depth)
        if depth == nil then depth = 1 end
        if type(o) == 'table' then
            local s = '{'
            depth = depth-1
            if depth >= 0 then
                for k,v in pairs(o) do
                    if type(k) ~= 'number' then k = '"'..k..'"' end
                    s = s .. '['..k..'] = ' .. util.xmp(v,depth) .. ','
                end
            else
                s = s..'?'
            end
            return s .. '} '
        else
            return tostring(o)
        end
    end
}
--]]

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
        channel = "presence-general_chat",
        channel_data = {
            user_id = 1,           -- Example user id
            username = "username1" --Example username 
        },
        disconnectCallback = function()
            scene:dispatchEvent("chatDisconnect",scene)
        end,
        pushererrorCallback = function()
            scene:dispatchEvent("chatError", scene)
            scene:dispatchEvent("chatDisconnect",scene)
        end,
        readyCallback = function(params)
            print("Connected to chat server.")
            mychathub.subscribe({
                channel = params.channel,
                channel_data = params.channel_data,
                bindings = {
                    ["client-message"] = function(t_client_msg)
                        print("pusher_internal:client-message")
                        print("event", t_client_msg.event)
                        print("channel", t_client_msg.channel)
                        print("data", t_client_msg.data)
                    end,
                    ["pusher_internal:subscription_succeeded"] = function(t_sub_state)
                        print("pusher_internal:subscription_succeeded")
                        print("event", t_sub_state.event)
                        print("channel", t_sub_state.channel)
                        print("data", t_sub_state.data)
                        print("Joined "..params.channel)

                        -- example message to broadcast when you join the channel
                        --mychathub.publish('{"event":"client-message","data": {"message":"'..params.channel_data.username..' joined '..params.channel..'"},"channel":"'..params.channel..'"}')
                    end
                }
            })
        end
    })




]]--
