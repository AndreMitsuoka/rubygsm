#!/usr/bin/env ruby
#:include:../../README.rdoc
#:title:Ruby GSM
#--
# vim: noet
#++

# standard library
require "timeout.rb"
require "date.rb"

# gems (we're using the ruby-serialport gem
# now, so we can depend upon it in our spec)
require "rubygems"
require "serialport"


class GsmModem
	include Timeout
	
	
	attr_accessor :verbosity, :read_timeout
	attr_reader :device
	
	# call-seq:
	#   GsmModem.new(port, verbosity=:warn)
	#
	# Create a new instance, to initialize and communicate exclusively with a
	# single modem device via the _port_ (which is usually either /dev/ttyS0
	# or /dev/ttyUSB0), and start logging to *rubygsm.log* in the chdir.
	def initialize(port, verbosity=:warn, baud=9600, cmd_delay=0.1)
	
		# port, baud, data bits, stop bits, parity
		@device = SerialPort.new(port, baud, 8, 1, SerialPort::NONE)
		
		@cmd_delay = cmd_delay
		@verbosity = verbosity
		@read_timeout = 10
		@locked_to = false
		
		# keep track of the depth which each
		# thread is indented in the log
		@log_indents = {}
		@log_indents.default = 0
		
		# to keep multi-part messages until
		# the last part is delivered
		@multipart = {}
		
		# (re-) open the full log file
		@log = File.new "rubygsm.log", "w"
		
		# initialization message (yes, it's underlined)
		msg = "RubyGSM Initialized at: #{Time.now}"
		log msg + "\n" + ("=" * msg.length), :file
		
		# to store incoming messages
		# until they're dealt with by
		# someone else, like a commander
		@incoming = []
		
		# initialize the modem
		command "ATE0"      # echo off
		command "AT+CMEE=1" # useful errors
		command "AT+WIND=0" # no notifications
		command "AT+CMGF=1" # switch to text mode
	end
	
	
	
	
	private
	
	
	INCOMING_FMT = "%y/%m/%d,%H:%M:%S%Z" #:nodoc:
	
	def parse_incoming_timestamp(ts)
		# extract the weirdo quarter-hour timezone,
		# convert it into a regular hourly offset
		ts.sub! /(\d+)$/ do |m|
			sprintf("%02d", (m.to_i/4))
		end
		
		# parse the timestamp, and attempt to re-align
		# it according to the timezone we extracted
		DateTime.strptime(ts, INCOMING_FMT)
	end
	
	def parse_incoming_sms!(lines)
		n = 0
		
		# iterate the lines like it's 1984
		# (because we're patching the array,
		# which is hard work for iterators)
		while n < lines.length
			
			# not a CMT string? ignore it
			unless lines && lines[n] && lines[n][0,5] == "+CMT:"
				n += 1
				next
			end
			
			# since this line IS a CMT string (an incomming
			# SMS), parse it and store it to deal with later
			unless m = lines[n].match(/^\+CMT: "(.+?)",.*?,"(.+?)".*?$/)
				err = "Couldn't parse CMT data: #{buf}"
				raise RuntimeError.new(err)
			end
			
			# extract the meta-info from the CMT line,
			# and the message from the FOLLOWING line
			from, timestamp = *m.captures
			msg = lines[n+1].strip
			
			# notify the network that we accepted
			# the incoming message (for read receipt)
			# BEFORE pushing it to the incoming queue
			# (to avoid really ugly race condition)
			command "AT+CNMA"
			
			# we might abort if this is
			catch :skip_processing do
			
				# multi-part messages begin with ASCII char 130
				if (msg[0] == 130) and (msg[1].chr == "@")
					text = msg[7,999]
					
					# ensure we have a place for the incoming
					# message part to live as they are delivered
					@multipart[from] = []\
						unless @multipart.has_key?(from)
					
					# append THIS PART
					@multipart[from].push(text)
					
					# add useless message to log
					part = @multipart[from].length
					log "Received part #{part} of message from: #{from}"
					
					# abort if this is not the last part
					throw :skip_processing\
						unless (msg[5] == 173)
					
					# last part, so switch out the received
					# part with the whole message, to be processed
					# below (the sender and timestamp are the same
					# for all parts, so no change needed there)
					msg = @multipart[from].join("")
					@multipart.delete(from)
				end
				
				# just in case it wasn't already obvious...
				log "Received message from #{from}: #{msg}"
			
				# store the incoming data to be picked up
				# from the attr_accessor as a tuple (this
				# is kind of ghetto, and WILL change later)
				dt = parse_incoming_timestamp(timestamp)
				@incoming.push [from, dt, msg]
			end
			
			# drop the two CMT lines (meta-info and message),
			# and patch the index to hit the next unchecked
			# line during the next iteration
			lines.slice!(n,2)
			n -= 1
		end
	end
	
	
	# write a string to the modem immediately,
	# without waiting for the lock
	def write(str)
		log "Write: #{str.inspect}", :traffic
		
		begin
			str.each_byte do |b|
				@device.putc(b.chr)
			end
		
		# the device couldn't be written to,
		# which probably means that it has
		# crashed or been unplugged
		rescue Errno::EIO
			raise GsmModem::WriteError
		end
	end
	
	
	# read from the modem (blocking) until
	# the term character is hit, and return
	def read(term=nil)
		term = "\r\n" if term==nil
		term = [term] unless term.is_a? Array
		buf = ""
		
		# include the terminator in the traffic dump,
		# if it's anything other than the default
		#suffix = (term != ["\r\n"]) ? " (term=#{term.inspect})" : ""
		#log_incr "Read" + suffix, :traffic
		
		begin
			timeout(@read_timeout) do
				while true do
					char = @device.getc
					
					# die if we couldn't read
					# (nil signifies an error)
					raise GsmModem::ReadError\
						if char.nil?
					
					# convert the character to ascii,
					# and append it to the tmp buffer
					buf << sprintf("%c", char)
				
					# if a terminator was just received,
					# then return the current buffer
					term.each do |t|
						len = t.length
						if buf[-len, len] == t
							log "Read: #{buf.inspect}", :traffic
							return buf.strip
						end
					end
				end
			end
		
		# reading took too long, so intercept
		# and raise a more specific exception
		rescue Timeout::Error
			log = "Read: Timed out", :warn
			raise TimeoutError
		end
	end
	
	
	# issue a single command, and wait for the response
	def command(cmd, resp_term=nil, write_term="\r")
		begin
			out = ""
			log_incr "Command: #{cmd}"
			
			exclusive do
				write(cmd + write_term)
				out = wait(resp_term)
			end
		
			# some hardware (my motorola phone) adds extra CRLFs
			# to some responses. i see no reason that we need them
			out.delete ""
		
			# for the time being, ignore any unsolicited
			# status messages. i can't seem to figure out
			# how to disable them (AT+WIND=0 doesn't work)
			out.delete_if do |line|
				(line[0,6] == "+WIND:") or
				(line[0,6] == "+CREG:") or
				(line[0,7] == "+CGREG:")
			end
		
			# parse out any incoming sms that were bundled
			# with this data (to be fetched later by an app)
			parse_incoming_sms!(out)
		
			# log the modified output
			log_decr "=#{out.inspect}"
		
			# rest up for a bit (modems are
			# slow, and get confused easily)
			sleep(@cmd_delay)
			return out
		
		# if the 515 (please wait) error was thrown,
		# then automatically re-try the command after
		# a short delay. for others, propagate
		rescue Error => err
			log "Rescued: #{err.desc}"
			
			if (err.type == "CMS") and (err.code == 515)
				sleep 2
				retry
			end
			
			log_decr
			raise
		end
	end
	
	
	def query(cmd)
		log_incr "Query: #{cmd}"
		out = command cmd
	
		# only very simple responses are supported
		# (on purpose!) here - [response, crlf, ok]
		if (out.length==2) and (out[1]=="OK")
			log_decr "=#{out[0].inspect}"
			return out[0]
		
		else
			err = "Invalid response: #{out.inspect}"
			raise RuntimeError.new(err)
		end
	end
	
	
	# just wait for a response, by reading
	# until an OK or ERROR terminator is hit
	def wait(term=nil)
		buffer = []
		log_incr "Waiting for response"
		
		while true do
			buf = read(term)
			buffer.push(buf)
		
			# some errors contain useful error codes,
			# so raise a proper error with a description
			if m = buf.match(/^\+(CM[ES]) ERROR: (\d+)$/)
				log_then_decr "!! Raising GsmModem::Error #{$1} #{$2}"
				raise Error.new(*m.captures)
			end
		
			# some errors are not so useful :|
			if buf == "ERROR"
				log_then_decr "!! Raising GsmModem::Error"
				raise Error
			end
		
			# most commands return OK upon success, except
			# for those which prompt for more data (CMGS)
			if (buf=="OK") or (buf==">")
				log_decr "=#{buffer.inspect}"
				return buffer
			end
		
			# some commands DO NOT respond with OK,
			# even when they're successful, so check
			# for those exceptions manually
			if m = buf.match(/^\+CPIN: (.+)$/)
				log_decr "=#{buffer.inspect}"
				return buffer
			end
		end
	end
	
	
	def exclusive &blk
		old_lock = nil
		
		begin
			
			# prevent other threads from issuing
			# commands while this block is working
			if @locked_to and (@locked_to != Thread.current)
				log "Locked by #{@locked_to["name"]}, waiting..."
			
				# wait for the modem to become available,
				# so we can issue commands from threads
				while @locked_to
					sleep 0.05
				end
			end
			
			# we got the lock!
			old_lock = @locked_to
			@locked_to = Thread.current
			log_incr "Got lock"
		
			# perform the command while
			# we have exclusive access
			# to the modem device
			yield
			
		
		# something went bang, which happens, but
		# just pass it on (after unlocking...)
		rescue GsmModem::Error
			raise
		
		
		# no message, but always un-
		# indent subsequent log messages
		# and RELEASE THE LOCK
		ensure
			@locked_to = old_lock
			Thread.pass
			log_decr
		end
	end
	
	
	
	
	public
	
	
	# call-seq:
	#   hardware => hash
	#
	# Returns a hash of containing information about the physical
	# modem. The contents of each value are entirely manufacturer
	# dependant, and vary wildly between devices.
	#
	#   modem.hardware => { :manufacturer => "Multitech".
	#                       :model        => "MTCBA-G-F4", 
	#                       :revision     => "123456789",
	#                       :serial       => "ABCD" }
	def hardware
		return {
			:manufacturer => query("AT+CGMI"),
			:model        => query("AT+CGMM"),
			:revision     => query("AT+CGMR"),
			:serial       => query("AT+CGSN") }
	end
	
	
	# The values accepted and returned by the AT+WMBS
	# command, mapped to frequency bands, in MHz. Copied
	# directly from the MultiTech AT command-set reference
	Bands = {
		"0" => "850",
		"1" => "900",
		"2" => "1800",
		"3" => "1900",
		"4" => "850/1900",
		"5" => "900E/1800",
		"6" => "900E/1900"
	}
	
	# call-seq:
	#   compatible_bands => array
	#
	# Returns an array containing the bands supported by
	# the modem.
	def compatible_bands
		data = query("AT+WMBS=?")
		
		# wmbs data is returned as something like:
		#  +WMBS: (0,1,2,3,4,5,6),(0-1)
		#  +WMBS: (0,3,4),(0-1)
		# extract the numbers with a regex, and
		# iterate each to resolve it to a more
		# readable description
		if m = data.match(/^\+WMBS: \(([\d,]+)\),/)
			return m.captures[0].split(",").collect do |index|
				Bands[index]
			end
		
		else
			# Todo: Recover from this exception
			err = "Not WMBS data: #{data.inspect}"
			raise RuntimeError.new(err)
		end
	end
	
	# call-seq:
	#   band => string
	#
	# Returns a string containing the band
	# currently selected for use by the modem.
	def band
		data = query("AT+WMBS?")
		if m = data.match(/^\+WMBS: (\d+),/)
			return Bands[m.captures[0]]
			
		else
			# Todo: Recover from this exception
			err = "Not WMBS data: #{data.inspect}"
			raise RuntimeError.new(err)
		end
	end
	
	
	# call-seq:
	#   pin_required? => true or false
	#
	# Returns true if the modem is waiting for a SIM PIN. Some SIM cards will refuse
	# to work until the correct four-digit PIN is provided via the _use_pin_ method.
	def pin_required?
		not command("AT+CPIN?").include?("+CPIN: READY")
	end
	
	
	# call-seq:
	#   use_pin(pin) => true or false
	#
	# Provide a SIM PIN to the modem, and return true if it was accepted.
	def use_pin(pin)
		
		# if the sim is already ready,
		# this method isn't necessary
		if pin_required?
			begin
				command "AT+CPIN=#{pin}"
		
			# if the command failed, then
			# the pin was not accepted
			rescue GsmModem::Error
				return false
			end
		end
		
		# no error = SIM
		# PIN accepted!
		true
	end
	
	
	# call-seq:
	#   signal => fixnum or nil
	#
	# Returns an fixnum between 1 and 99, representing the current
	# signal strength of the GSM network, or nil if we don't know.
	def signal_strength
		data = query("AT+CSQ")
		if m = data.match(/^\+CSQ: (\d+),/)
			
			# 99 represents "not known or not detectable",
			# but we'll use nil for that, since it's a bit
			# more ruby-ish to test for boolean equality
			csq = m.captures[0].to_i
			return (csq<99) ? csq : nil
			
		else
			# Todo: Recover from this exception
			err = "Not CSQ data: #{data.inspect}"
			raise RuntimeError.new(err)
		end
	end
	
	
	# call-seq:
	#   wait_for_network
	#
	# Blocks until the signal strength indicates that the
	# device is active on the GSM network. It's a good idea
	# to call this before trying to send or receive anything.
	def wait_for_network
		
		# keep retrying until the
		# network comes up (if ever)
		until csq = signal_strength
			sleep 1
		end
		
		# return the last
		# signal strength
		return csq
	end
	
	
	# call-seq:
	#   send(recipient, message) => true or false
	#
	# Sends an SMS message, and returns true if the network
	# accepted it for delivery. We currently can't handle read
	# receipts, so have no way of confirming delivery.
	#
	# Note: the recipient is passed directly to the modem, which
	# in turn passes it straight to the SMSC (sms message center).
	# for maximum compatibility, use phone numbers in international
	# format, including the *plus* and *country code*.
	def send(to, msg)
		
		# the number must be in the international
		# format for some SMSCs (notably, the one
		# i'm on right now) so maybe add a PLUS
		#to = "+#{to}" unless(to[0,1]=="+")
		
		# 1..9 is a special number which does not
		# result in a real sms being sent (see inject.rb)
		if to == "+123456789"
			log "Not sending test message: #{msg}"
			return false
		end
		
		# block the receiving thread while
		# we're sending. it can take some time
		exclusive do
			log_incr "Sending SMS to #{to}: #{msg}"
			
			# initiate the sms, and wait for either
			# the text prompt or an error message
			command "AT+CMGS=\"#{to}\"", ["\r\n", "> "]
			
			begin
				# send the sms, and wait until
				# it is accepted or rejected
				write "#{msg}#{26.chr}"
				wait
				
			# if something went wrong, we are
			# be stuck in entry mode (which will
			# result in someone getting a bunch
			# of AT commands via sms!) so send
			# an escpae, to... escape
			rescue Exception, Timeout::Error => err
				log "Rescued #{err.desc}"
				return false
				#write 27.chr
				#wait
			end
			
			log_decr
		end
				
		# if no error was raised,
		# then the message was sent
		return true
	end
	
	
	# call-seq:
	#   receive(callback_method, interval=5, join_thread=false)
	#
	# Starts a new thread, which polls the device every _interval_
	# seconds to capture incoming SMS and call _callback_method_
	# for each.
	#
	#   class Receiver
	#     def incoming(caller, datetime, message)
	#       puts "From #{caller} at #{datetime}:", message
	#     end
	#   end
	#   
	#   # create the instances,
	#   # and start receiving
	#   rcv = Receiver.new
	#   m = GsmModem.new "/dev/ttyS0"
	#   m.receive inst.method :incoming
	#   
	#   # block until ctrl+c
	#   while(true) { sleep 2 }
	#
	# Note: New messages may arrive at any time, even if this method's
	# receiver thread isn't waiting to process them. They are not lost,
	# but cached in @incoming until this method is called.
	def receive(callback, interval=5, join_thread=false)
		@polled = 0
		
		@thr = Thread.new do
			Thread.current["name"] = "receiver"
			
			# keep on receiving forever
			while true
				command "AT"
				
				# enable new message notification mode
				# every ten intevals, in case the
				# modem "forgets" (power cycle, etc)
				if (@polled % 10) == 0
					command "AT+CNMI=2,2,0,0,0"
				end
				
				# if there are any new incoming messages,
				# iterate, and pass each to the receiver
				# in the same format that they were built
				# back in _parse_incoming_sms!_
				unless @incoming.empty?
					@incoming.each do |inc|
						begin
							callback.call *inc
						
						rescue StandardError => err
							log "Error in callback: #{err}"
						end
					end
					
					# we have dealt with all of the pending
					# messages. todo: this is a ridiculous
					# race condition, and i fail at ruby
					@incoming.clear
				end
				
				# re-poll every
				# five seconds
				sleep(interval)
				@polled += 1
			end
		end
		
		# it's sometimes handy to run single-
		# threaded (like debugging handsets)
		@thr.join if join_thread
	end
end
