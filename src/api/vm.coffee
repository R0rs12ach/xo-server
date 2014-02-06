{
  isArray: $isArray
} = require 'underscore'

{
  $each
} = require '../utils'

$js2xml = do ->
  {Builder} = require 'xml2js'
  builder = new Builder {
    xmldec: {
      # Do not include an XML header.
      #
      # This is not how this setting should be set but due to the
      # implementation of both xml2js and xmlbuilder-js it works.
      #
      # TODO: Find a better alternative.
      headless: true
    }
  }
  builder.buildObject.bind builder

$isVMRunning = do ->
  runningStates = {
    'Paused': true
    'Running': true
  }

  (VM) -> !!runningStates[VM.power_state]

#=====================================================================

exports.create = ->
  # Validates and retrieves the parameters.
  {
    installation
    name_label
    template
    VDIs
    VIFs
  } = @getParams {
    installation: {
      type: 'object'
      properties: {
        method: { type: 'string' }
        repository: { type: 'string' }
      }
    }

    # Name of the new VM.
    name_label: { type: 'string' }

    # TODO: add the install repository!
    # VBD.insert/eject
    # Also for the console!

    # UUID of the template the VM will be created from.
    template: { type: 'string' }

    # Virtual interfaces to create for the new VM.
    VIFs: {
      type: 'array'
      items: {
        type: 'object'
        properties: {
          # UUID of the network to create the interface in.
          network: { type: 'string' }

          MAC: {
            optional: true # Auto-generated per default.
            type: 'string'
          }
        }
      }
    }

    # Virtual disks to create for the new VM.
    VDIs: {
      optional: true # If not defined, use the template parameters.
      type: 'array'
      items: {
        type: 'object'
        properties: {
          bootable: { type: 'boolean' }
          device: { type: 'string' }
          size: { type: 'integer' }
          SR: { type: 'string' }
          type: { type: 'string' }
        }
      }
    }
  }

  # Current user must be an administrator.
  @checkPermission 'admin'

  # Gets the template.
  template = @getObject template
  @throw 'NO_SUCH_OBJECT' unless template


  # Gets the corresponding connection.
  xapi = @getXAPI template

  # Clones the VM from the template.
  ref = xapi.call 'VM.clone', template.ref, name_label

  # Creates associated virtual interfaces.
  $each VIFs, (VIF) =>
    network = @getObject VIF.network

    xapi.call 'VIF.create', {
      device: '0'
      MAC: VIF.MAC ? ''
      MTU: '1500'
      network: network.ref
      other_config: {}
      qos_algorithm_params: {}
      qos_algorithm_type: ''
      VM: ref
    }

  # TODO: ? xapi.call 'VM.set_PV_args', ref, 'noninteractive'

  # Updates the number of existing vCPUs.
  if CPUs?
    xapi.call 'VM.set_VCPUs_at_startup', ref, CPUs

  if VDIs?
    # Transform the VDIs specs to conform to XAPI.
    $each VDIs, (VDI, key) ->
      VDI.bootable = if VDI.bootable then 'true' else 'false'
      VDI.size = "#{VDI.size}"
      VDI.sr = VDI.SR
      delete VDI.SR

      # Preparation for the XML generation.
      VDIs[key] = { $: VDI }

    # Converts the provision disks spec to XML.
    VDIs = $js2xml {
      provision: {
        disk: VDIs
      }
    }

    # Replace the existing entry in the VM object.
    try xapi.call 'VM.remove_from_other_config', ref, 'disks'
    xapi.call 'VM.add_to_other_config', ref, 'disks', VDIs

    switch installation.method
      when 'cdrom'
        xapi.call(
          'VM.add_to_other_config', ref
          'install-repository', 'cdrom'
        )
      when 'ftp', 'http', 'nfs'
        xapi.call(
          'VM.add_to_other_config', ref
          'install-repository', installation.repository
        )
      else
        @throw(
          'INVALID_PARAMS'
          "Unsupported installation method #{installation.method}"
        )

    # Creates the VDIs and executes the initial steps of the
    # installation.
    xapi.call 'VM.provision', ref

    # Gets the VM record.
    VM = xapi.call 'VM.get_record', ref

    if installation.method is 'cdrom'
      # Gets the VDI containing the ISO to mount.
      try
        VDIref = (@getObject installation.repository).ref
      catch
        @throw 'NO_SUCH_OBJECT', 'installation.repository'

      # Finds the VBD associated to the newly created VM which is a
      # CD.
      CD_drive = null
      $each VM.VBDs, (ref, _1, _2, done) ->
        VBD = xapi.call 'VBD.get_record', ref
        # TODO: Checks it has been correctly retrieved.
        if VBD.type is 'CD'
          CD_drive = VBD.ref
          done

      # No CD drives have been found, creates one.
      unless CD_drive
        # See: https://github.com/xenserver/xenadmin/blob/da00b13bb94603b369b873b0a555d44f15fa0ca5/XenModel/Actions/VM/CreateVMAction.cs#L370
        CD_drive = xapi.call 'VBD.create', {
          bootable: true
          device: ''
          empty: true
          mode: 'RO'
          other_config: {}
          qos_algorithm_params: {}
          qos_algorithm_type: ''
          type: 'CD'
          unpluggable: true
          userdevice: (xapi.call 'VM.get_allowed_VBD_devices', ref)[0]
          VDI: 'OpaqueRef:NULL'
          VM: ref
        }

      # If the CD drive as not been found, throws.
      @throw 'NO_SUCH_OBJECT' unless CD_drive

      # Mounts the VDI into the VBD.
      xapi.call 'VBD.insert', CD_drive, VDIref

  # The VM should be properly created.
  VM.uuid

exports.delete = ->
  {
    id
    delete_disks: deleteDisks
  } = @getParams {
    id: { type: 'string' }

    delete_disks: {
      optional: true
      type: 'boolean'
    }
  }

  # Current user must be an administrator.
  @checkPermission 'admin'

  try
    VM = @getObject id
  catch
    @throw 'NO_SUCH_OBJECT'

  if $isVMRunning VM
    @throw 'INVALID_PARAMS', 'The VM can only be deleted when halted'

  xapi = @getXAPI VM

  if deleteDisks
    $each VM.$VBDs, (ref) =>
      try
        VBD = @getObject ref
      catch e
        return

      return if VBD.read_only or not VBD.VDI?

      xapi.call 'VDI.destroy', VBD.VDI

  xapi.call 'VM.destroy', VM.ref

exports.migrate = ->
  {id, host_id} = @getParams {
    # Identifier of the VM to migrate.
    id: { type: 'string' }

    # Identifier of the host to migrate to.
    host_id: { type: 'string' }
  }

  # Current user must be an administrator.
  @checkPermission 'admin'

  try
    VM = @getObject id
    host = @getObject host_id
  catch
    @throw 'NO_SUCH_OBJECT'

  unless $isVMRunning VM
    @throw 'INVALID_PARAMS', 'The VM can only be migrated when running'

  xapi = @getXAPI VM

  xapi.call 'VM.pool_migrate', VM.ref, host.ref, {}

exports.set = ->
  params = @getParams {
    # Identifier of the VM to update.
    id: { type: 'string' }

    name_label: { type: 'string', optional: true }

    name_description: { type: 'string', optional: true }

    # Number of virtual CPUs to allocate.
    CPUs: { type: 'integer', optional: true }

    # Memory to allocate (in bytes).
    #
    # Note: static_min ≤ dynamic_min ≤ dynamic_max ≤ static_max
    memory: { type: 'integer', optional: true }
  }

  # Current user must be an administrator.
  @checkPermission 'admin'

  try
    VM = @getObject params.id
  catch
    @throw 'NO_SUCH_OBJECT'

  xapi = @getXAPI VM

  {ref} = VM

  # Memory.
  if 'memory' of params
    {memory} = params

    if memory < VM.memory.static[0]
      @throw(
        'INVALID_PARAMS'
        "cannot set memory below the static minimum (#{VM.memory.static[0]})"
      )

    if ($isVMRunning VM) and memory > VM.memory.static[1]
      @throw(
        'INVALID_PARAMS'
        "cannot set memory above the static maximum (#{VM.memory.static[1]}) "+
          "for a running VM"
      )

    if memory < VM.memory.dynamic[0]
      xapi.call 'VM.set_memory_dynamic_min', ref, "#{memory}"
    else if memory > VM.memory.static[1]
      xapi.call 'VM.set_memory_static_max', ref, "#{memory}"
    xapi.call 'VM.set_memory_dynamic_max', ref, "#{memory}"

  # Number of CPUs.
  if 'CPUs' of params
    {CPUs} = params

    if $isVMRunning VM
      if CPUs > VM.CPUs.max
        @throw(
          'INVALID_PARAMS'
          "cannot set CPUs above the static maximum (#{VM.CPUs.max}) "+
            "for a running VM"
        )
      xapi.call 'VM.set_VCPUs_number_live', ref, "#{CPUs}"
    else
      if CPUs > VM.CPUs.max
        xapi.call 'VM.set_VCPUs_max', ref, "#{CPUs}"
      xapi.call 'VM.set_VCPUs_at_startup', ref, "#{CPUs}"

  # Other fields.
  for param, fields of {
    'name_label'
    'name_description'
  }
    continue unless param of params

    for field in (if $isArray fields then fields else [fields])
      xapi.call "VM.set_#{field}", ref, "#{params[param]}"

exports.restart = ->
  {
    id
    force
  } = @getParams {
    id: { type: 'string' }
    force: { type: 'boolean' }
  }

  @checkPermission 'admin'

  try
    VM = @getObject id
  catch
    @throw 'NO_SUCH_OBJECT'

  xapi = @getXAPI VM

  try
    # Attempts a clean reboot.
    xapi.call 'VM.clean_reboot', VM.ref
  catch error
    return unless error[0] is 'VM_MISSING_PV_DRIVERS'

    @throw 'INVALID_PARAMS' unless force

    xapi.call 'VM.hard_reboot', VM.ref

  true


exports.start = ->
  {id} = @getParams {
    id: { type: 'string' }
  }

  try
    VM = @getObject id
  catch
    @throw 'NO_SUCH_OBJECT'

  (@getXAPI VM).call(
    'VM.start', VM.ref
    false # Start paused?
    false # Skips the pre-boot checks?
  )

  true

exports.stop = ->
  {
    id
    force
  } = @getParams {
    id: { type: 'string' }
    force: { type: 'boolean' }
  }

  @checkPermission 'admin'

  try
    VM = @getObject id
  catch
    @throw 'NO_SUCH_OBJECT'

  xapi = @getXAPI VM

  try
    # Attempts a clean shutdown.
    xapi.call 'VM.clean_shutdown', VM.ref
  catch error
    return unless error[0] is 'VM_MISSING_PV_DRIVERS'

    @throw 'INVALID_PARAMS' unless force

    xapi.call 'VM.hard_shutdown', VM.ref

  true