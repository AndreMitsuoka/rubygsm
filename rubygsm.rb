#!/usr/bin/env ruby
# vim: noet

require "serialport.so"


class Modem
	class Error < StandardError
		ERRORS = {
			"CME" => {
				3 =>   "Operation not allowed",
				4 =>   "Operation not supported",
				5 =>   "PH-SIM PIN required (SIM lock)",
				10 =>  "SIM not inserted",
				11 =>  "SIM PIN required",
				12 =>  "SIM PUK required",
				13 =>  "SIM failure",
				16 =>  "Incorrect password",
				17 =>  "SIM PIN2 required",
				18 =>  "SIM PUK2 required",
				20 =>  "Memory full",
				21 =>  "Invalid index",
				22 =>  "Not found",
				24 =>  "Text string too long",
				26 =>  "Dial string too long",
				27 =>  "Invalid characters in dial string",
				30 =>  "No network service",
				32 =>  "Network not allowed – emergency calls only",
				40 =>  "Network personal PIN required (Network lock)",
				103 => "Illegal MS (#3)",
				106 => "Illegal ME (#6)",
				107 => "GPRS services not allowed (#7)",
				111 => "PLMN not allowed (#11)",
				112 => "Location area not allowed (#12)",
				113 => "Roaming not allowed in this area (#13)",
				132 => "service option not supported (#32)",
				133 => "requested service option not subscribed (#33)",
				134 => "service option temporarily out of order (#34)",
				148 => "unspecified GPRS error",
				149 => "PDP authentication failure",
				150 => "invalid mobile class"
			}
			"CMS" => {
				301 => "SMS service of ME reserved",
				302 => "Operation not allowed",
				303 => "Operation not supported",
				304 => "Invalid PDU mode parameter",
				305 => "Invalid text mode parameter",
				310 => "SIM not inserted",
				311 => "SIM PIN required",
				312 => "PH-SIM PIN required",
				313 => "SIM failure",
				316 => "SIM PUK required",
				317 => "SIM PIN2 required",
				318 => "SIM PUK2 required",
				321 => "Invalid memory index",
				322 => "SIM memory full",
				330 => "SC address unknown",
				340 => "no +CNMA acknowledgement expected"
			}
		}
		
		attr_reader :command, :response, :type, :code
		def initialize(cmd, rsp, type=nil, code=nil)
			@command = cmd
			@response = rsp
			@type = type
			@code = code.to_i
		end
		
		def desc
			return(ERRORS[@type][@code])\
				if(@type and ERRORS[@type] and @code)
		end
	end
	
	attr_reader :device, :traffic
	def initialize(port, baud=9600)
		# port, baud, data bits, stop bits, parity
		@device = SerialPort.new(port, baud, 8, 1, SerialPort::NONE)
		@traffic = []
		@buffer = []
		
		query("CMEE=1")
	end
	
	# send a STRING to the modem
	def send(str)
		@traffic.push("> #{str}")
		(str + "\n").each_byte do |b|
			@device.putc(b.chr)
		end
	end
	
	# read from the modem (blocking) until
	# the term character is hit, and return
	def read(term="\r\n")
		buf = ""
		
		while true do
			buf << sprintf("%c", @device.getc)
			if buf.end_with?(term)
				output = buf.strip
				@traffic.push("< #{output}")
				return output
			end
		end
	end
	
	# issue a command, and read until
	# a valid response terminator is hit
	def command(cmd)
		buffer = []
		send(cmd)
		
		while true do
			buf = read
			
			# don't store the echoed being
			# echoed back, or empty lines
			unless (buf==cmd) or buf.empty?
				buffer.push(buf)
			end
			
			# some errors contain useful error codes,
			# so raise a proper error with a description
			if m = buf.match(/^\+(CM[ES]) ERROR: (\d+)$/)
				raise Error.new(cmd, buffer, *m.captures)
			end
			
			# some errors are not so useful :|
			raise Error.new(cmd, buffer)\
				if buf == "ERROR"
			
			# most commands end their responses with OK
			# since this method is assumed to succeed if
			# it does not raise, just return the meat
			return buffer if(buf == "OK")
			
			# some commands DO NOT respond with OK,
			# so we must watch their output manually,
			# and patch on the OK ourselves
			if cmd.match(/^AT\+CPIN/)
				if m = buf.match(/^\+CPIN: (.+)$/)
					buffer.push("OK")
					return buffer
				end
			end
		end
	end
	
	# issue a simple (one-line response) command
	def query(cmd)
		resp = command("AT+#{cmd}")
		if resp.last == "OK"
			return resp[-2]
			
		else
			raise Error.new(cmd, resp)
		end
	end
	
	def close
		@device.close
	end
end

class ModemCommander
	def initialize(modem)
		@m = modem
	end
	
	def identify
		# returns: manufacturer, model, revision, serial
		[ @m.query("CGMI"), @m.query("CGMM"), @m.query("CGMR"), @m.query("CGSN") ]
	end
	
	def ready?
		return(@m.query("CPIN?") == "+CPIN: READY")
	end
	
	def send(to, msg)
		@m.send("AT+CMGS=\"#{to}\"")
		@m.read("> ")
		@m.send("#{msg}\e")
		@m.read
		@m.read
	end
end


if __FILE__ == $0
	begin
		m = Modem.new "/dev/ttyUSB0"
		mc = ModemCommander.new(m)
		#puts mc.identify
		puts mc.ready?
		puts mc.send("+251911505181", "RubyGSM is rocking your socks off")



	rescue Modem::Error => err
		puts "Error"
		puts "  Command:  #{err.command.inspect}"
		puts "  Response: #{err.response.inspect}"
		#puts "  Type:     #{err.type}"
		#puts "  Code:     #{err.code}"
		puts "  Desc:     #{err.desc}"

	ensure
		puts "\n---- (traffic) ----"
		puts m.traffic.join("\n")
		m.query("CFUN=1")
		m.close
	end
end

