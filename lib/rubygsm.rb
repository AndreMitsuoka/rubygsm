require "rubygsm/core"
require "rubygsm/errors"
require "rubygsm/log"

# messages are now passed around
# using objects, rather than flat
# arguments (from, time, msg, etc)
require "rubygsm/msg/incoming"
require "rubygsm/msg/outgoing"

# during development, it's important to EXPLODE
# as early as possible when something goes wrong
Thread.abort_on_exception = true
Thread.current["name"] = "main"
