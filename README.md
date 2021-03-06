pusherhub
=========

Lua Implementation of RFC 6455 and integrated with Pusher.com

The pusher docs are... hard to get through.
http://pusher.com/docs The API/Websocket information is mixed together. 
Some of it may be inaccurate and some details are spread throughout various disparate sections.

RFC I used was http://tools.ietf.org/html/rfc6455#section-5.5.3

This library depends on having a Pusher.com account and the Corona SDK (http://coronalabs.com)
This module could probably be adapted for use via the extended LUA libraries. 
I would not know how to do this, so I didn't.

Need help with this? jack9@pusherhub.jack9.org

---

From the coronalabs.com forum I got a particular question that I think is worth answering here.

> How do I actually use this after I connected?

I'm going to give the basic steps to get connected to pusher.com and then answer the question.

You must get a pusher.com account (even a free one) and you need to log in to your dashboard.
You should create a pusher.com app.
From the app (link) on your pusher.com dashboard, you can view your app_id, key, and secret values.

Configure the pusherhub object (mychathub in the example usage) with those values on instantiation.

    mychathub = pusherhub.new({
        app_id = '12345', -- Example
        key = '278d425bdf160c739803',    -- Example http://pusher.com/docs/auth_signatures
        secret = '7ad3773142a6692b25b8', -- Example http://pusher.com/docs/auth_signatures
        ....

After connecting to your own application and subscribing to a channel, you can send messages to the channel via

    mychathub.publish(msg)

where

    var msg = "whatever you want to broadcast to the channel"


The event that pusher.com sends out when a message is received on a channel is called "client-message"
Anyone connected to the channel via another pusherhub object connected to your app and the same channel,
will receive the message in the function assigned to the client-message binding (it must be a function).
What's more, public channels are now restricted to server-side/custom messages. client-message, which comes
from another client, can't be forwarded to public channels. You must use a private- or presence- channel.

    mychathub.subscribe({
        channel = "presence-test_channel",
        channel_data = {              -- necessary for presence and private channels
            user_id = 1,              -- Example
            username = "testusername" -- Example
        },
        bindings = {
        
            --[[ this is what happens when any client sees the message, including user who sent it ]]--
            ["client-message"] = function(msg1)
                print("test client-message",msg1) 
            end,
            ....
 
This specific binding is called from this line, if you care to inspect the library file:

    self.channels[msg.channel]["events"][msg.event](msg)

I put the mychathub in the scope of my scene as leaving the scene will destroy the connection. Some people may want to create it as a global resource. It's up to you.

Some people aren't noticing the example usage at the bottom of the pusherhub.lua, so I've included it here.

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
