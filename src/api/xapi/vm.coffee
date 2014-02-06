$_ = require 'underscore'

#=====================================================================

# Definitions of the methods to generate.
defs = {
  pause: {}

  unpause: {}
}

#=====================================================================

# Generates methods.
$_.each defs, (def, name) ->
  method = name
  params = []

  if $_.isString def
    method = def
  else if $_.isArray def
    params = def
  else if $_.isObject def
    method = def.method if def.method?
    params = def.params if def.params?

  exports[name] = ->
    # This method expect to the VM's UUID.
    {id} = @getParams {
      id: { type: 'string' }
    }

    # The current session MUST have the `write`
    # permission.
    @checkPermission 'write'

    # Retrieves the VM with this UUID.
    try
      vm = @getObject id
    catch
      @throw 'NO_SUCH_OBJECT'

    # Gets the corresponding connection.
    xapi = @getXAPI vm
    xapi.call.apply xapi, ["VM.#{method}", vm.ref].concat params

    # Returns true.
    true