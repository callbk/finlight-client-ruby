# frozen_string_literal: true

# finlight-client 0.x was loaded with `require "finlight/client"`. 1.x speaks only the finlight API v3
# and is loaded with `require "finlight"`. This file only stops an accidental upgrade at the require
# with a clear message, instead of a NameError later on.
require_relative "version"

raise LoadError, "finlight-client #{Finlight::VERSION} speaks only the finlight API v3 and is loaded with " \
                 "`require \"finlight\"`, not `require \"finlight/client\"`. Code written for 0.x does not run " \
                 "unchanged; to stay on 0.x pin `gem \"finlight-client\", \"~> 0.1.0\"`. " \
                 "Migration guide: https://docs.finlight.me/migration/v2-to-v3"
