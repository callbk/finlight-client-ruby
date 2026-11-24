# frozen_string_literal: true

# The SDK's internal modules are private constants of Finlight (not public API). Tests reach them here.
module FinlightInternal
  %i[USER_AGENT TimeParse Decode Params ErrorParser Frames].each do |name|
    const_set(name, Finlight.const_get(name))
  end
end
