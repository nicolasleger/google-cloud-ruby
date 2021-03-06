# Copyright 2017 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require "google/cloud/pubsub/service"
require "google/cloud/pubsub/subscriber/stream"
require "monitor"

module Google
  module Cloud
    module Pubsub
      ##
      # Subscriber object used to stream and process messages from a
      # Subscription. See {Google::Cloud::Pubsub::Subscription#listen}
      #
      # @example
      #   require "google/cloud/pubsub"
      #
      #   pubsub = Google::Cloud::Pubsub.new
      #
      #   sub = pubsub.subscription "my-topic-sub"
      #
      #   subscriber = sub.listen do |received_message|
      #     # process message
      #     received_message.acknowledge!
      #   end
      #
      #   # Start background threads that will call the block passed to listen.
      #   subscriber.start
      #
      #   # Shut down the subscriber when ready to stop receiving messages.
      #   subscriber.stop.wait!
      #
      # @attr_reader [String] subscription_name The name of the subscription the
      #   messages are pulled from.
      # @attr_reader [Proc] callback The procedure that will handle the messages
      #   received from the subscription.
      # @attr_reader [Numeric] deadline The default number of seconds the stream
      #   will hold received messages before modifying the message's ack
      #   deadline. The minimum is 10, the maximum is 600. Default is 60.
      # @attr_reader [Integer] streams The number of concurrent streams to open
      #   to pull messages from the subscription. Default is 4.
      # @attr_reader [Integer] inventory The number of received messages to be
      #   collected by subscriber. Default is 1,000.
      # @attr_reader [Integer] callback_threads The number of threads used to
      #   handle the received messages. Default is 8.
      # @attr_reader [Integer] push_threads The number of threads to handle
      #   acknowledgement ({ReceivedMessage#ack!}) and delay messages
      #   ({ReceivedMessage#nack!}, {ReceivedMessage#delay!}). Default is 4.
      #
      class Subscriber
        include MonitorMixin

        attr_reader :subscription_name, :callback, :deadline, :streams,
                    :inventory, :callback_threads, :push_threads

        ##
        # @private Implementation attributes.
        attr_reader :stream_inventory, :stream_pool, :thread_pool, :service

        ##
        # @private Create an empty {Subscriber} object.
        def initialize subscription_name, callback, deadline: nil, streams: nil,
                       inventory: nil, threads: {}, service: nil
          @callback = callback
          @subscription_name = subscription_name
          @deadline = deadline || 60
          @streams = streams || 4
          @inventory = inventory || 1000
          @callback_threads = (threads[:callback] || 8).to_i
          @push_threads = (threads[:push] || 4).to_i

          @stream_inventory = @inventory.fdiv(@streams).ceil
          @service = service

          @started = nil
          @stopped = nil

          stream_pool = @streams.times.map do
            Thread.new { Stream.new self }
          end
          @stream_pool = stream_pool.map(&:value)

          super() # to init MonitorMixin
        end

        ##
        # Starts the subscriber pulling from the subscription and processing the
        # received messages.
        #
        # @return [Subscriber] returns self so calls can be chained.
        def start
          start_pool = synchronize do
            @started = true
            @stopped = false

            @stream_pool.map do |stream|
              Thread.new { stream.start }
            end
          end
          start_pool.map(&:join)

          self
        end

        ##
        # Begins the process of stopping the subscriber. Unhandled received
        # messages will be processed, but no new messages will be pulled from
        # the subscription. Use {#wait!} to block until the subscriber is fully
        # stopped and all received messages have been processed.
        #
        # @return [Subscriber] returns self so calls can be chained.
        def stop
          stop_pool = synchronize do
            @started = false
            @stopped = true

            @stream_pool.map do |stream|
              Thread.new { stream.stop }
            end
          end
          stop_pool.map(&:join)

          self
        end

        ##
        # Blocks until the subscriber is fully stopped and all received messages
        # have been handled. Does not stop the subscriber. To stop the
        # subscriber, first call {#stop} and then call {#wait!} to block until
        # the subscriber is stopped.
        #
        # @return [Subscriber] returns self so calls can be chained.
        def wait!
          wait_pool = synchronize do
            @stream_pool.map do |stream|
              Thread.new { stream.wait! }
            end
          end
          wait_pool.map(&:join)

          self
        end

        ##
        # Whether the subscriber has been started.
        #
        # @return [boolean] `true` when started, `false` otherwise.
        def started?
          synchronize { @started }
        end

        ##
        # Whether the subscriber has been stopped.
        #
        # @return [boolean] `true` when stopped, `false` otherwise.
        def stopped?
          synchronize { @stopped }
        end

        ##
        # @private
        def to_s
          format "(subscription: %s, streams: %i)", subscription_name, streams
        end

        ##
        # @private
        def inspect
          "#<#{self.class.name} #{self}>"
        end
      end
    end
  end
end
