require 'log4r'

require 'vagrant/driver/virtualbox_base'

module Vagrant
  module Driver
    # Driver for VirtualBox 4.0.x
    class VirtualBox_4_0 < VirtualBoxBase
      def initialize(uuid)
        super()

        @logger = Log4r::Logger.new("vagrant::driver::virtualbox_4_0")
        @uuid = uuid
      end

      def clear_forwarded_ports
        args = []
        read_forwarded_ports(@uuid).each do |nic, name, _, _|
          args.concat(["--natpf#{nic}", "delete", name])
        end

        execute("modifyvm", @uuid, *args) if !args.empty?
      end

      def clear_shared_folders
        execute("showvminfo", @uuid, "--machinereadable").split("\n").each do |line|
          if line =~ /^SharedFolderNameMachineMapping\d+="(.+?)"$/
            execute("sharedfolder", "remove", @uuid, "--name", $1.to_s)
          end
        end
      end

      def create_host_only_network(options)
        # Create the interface
        execute("hostonlyif", "create") =~ /^Interface '(.+?)' was successfully created$/
        name = $1.to_s

        # Configure it
        execute("hostonlyif", "ipconfig", name,
                "--ip", options[:ip],
                "--netmask", options[:netmask])

        # Return the details
        return {
          :name => name,
          :ip   => options[:ip],
          :netmask => options[:netmask]
        }
      end

      def delete
        execute("unregistervm", @uuid, "--delete")
      end

      def delete_unused_host_only_networks
        networks = []
        execute("list", "hostonlyifs").split("\n").each do |line|
          networks << $1.to_s if line =~ /^Name:\s+(.+?)$/
        end

        execute("list", "vms").split("\n").each do |line|
          if line =~ /^".+?"\s+\{(.+?)\}$/
            execute("showvminfo", $1.to_s, "--machinereadable").split("\n").each do |info|
              if info =~ /^hostonlyadapter\d+="(.+?)"$/
                networks.delete($1.to_s)
              end
            end
          end
        end

        networks.each do |name|
          execute("hostonlyif", "remove", name)
        end
      end

      def discard_saved_state
        execute("discardstate", @uuid)
      end

      def enable_adapters(adapters)
        args = []
        adapters.each do |adapter|
          args.concat(["--nic#{adapter[:adapter]}", adapter[:type].to_s])

          if adapter[:bridge]
            args.concat(["--bridgeadapter#{adapter[:adapter]}",
                         adapter[:bridge]])
          end

          if adapter[:hostonly]
            args.concat(["--hostonlyadapter#{adapter[:adapter]}",
                         adapter[:hostonly]])
          end

          if adapter[:mac_address]
            args.concat(["--macaddress#{adapter[:adapter]}",
                         adapter[:mac_address]])
          end
        end

        execute("modifyvm", @uuid, *args)
      end

      def execute_command(command)
        raw(*command)
      end

      def export(path)
        # TODO: Progress
        execute("export", @uuid, "--output", path.to_s)
      end

      def forward_ports(ports)
        args = []
        ports.each do |options|
          pf_builder = [options[:name],
                        options[:protocol] || "tcp",
                        "",
                        options[:hostport],
                        "",
                        options[:guestport]]

          args.concat(["--natpf#{options[:adapter] || 1}",
                       pf_builder.join(",")])
        end

        execute("modifyvm", @uuid, *args)
      end

      def halt
        execute("controlvm", @uuid, "poweroff")
      end

      def import(ovf, name)
        total = ""
        last  = 0
        execute("import", ovf, "--vsys", "0", "--vmname", name) do |type, data|
          if type == :stderr
            # Append the data so we can see the full view
            total << data

            # Break up the lines. We can't get the progress until we see an "OK"
            lines = total.split("\n")
            if lines.include?("OK.")
              # The progress of the import will be in the last line. Do a greedy
              # regular expression to find what we're looking for.
              if lines.last =~ /.+(\d{2})%/
                current = $1.to_i
                if current > last
                  last = current
                  yield current if block_given?
                end
              end
            end
          end
        end

        output = execute("list", "vms")
        if output =~ /^"#{name}" \{(.+?)\}$/
          return $1.to_s
        end

        nil
      end

      def read_forwarded_ports(uuid=nil, active_only=false)
        uuid ||= @uuid

        @logger.debug("read_forward_ports: uuid=#{uuid} active_only=#{active_only}")

        results = []
        current_nic = nil
        execute("showvminfo", uuid, "--machinereadable").split("\n").each do |line|
          # This is how we find the nic that a FP is attached to,
          # since this comes first.
          current_nic = $1.to_i if line =~ /^nic(\d+)=".+?"$/

          # If we care about active VMs only, then we check the state
          # to verify the VM is running.
          if active_only && line =~ /^VMState="(.+?)"$/ && $1.to_s != "running"
            return []
          end

          # Parse out the forwarded port information
          if line =~ /^Forwarding.+?="(.+?),.+?,.*?,(.+?),.*?,(.+?)"$/
            result = [current_nic, $1.to_s, $2.to_i, $3.to_i]
            @logger.debug("  - #{result.inspect}")
            results << result
          end
        end

        results
      end

      def read_bridged_interfaces
        execute("list", "bridgedifs").split("\n\n").collect do |block|
          info = {}

          block.split("\n").each do |line|
            if line =~ /^Name:\s+(.+?)$/
              info[:name] = $1.to_s
            elsif line =~ /^IPAddress:\s+(.+?)$/
              info[:ip] = $1.to_s
            elsif line =~ /^NetworkMask:\s+(.+?)$/
              info[:netmask] = $1.to_s
            elsif line =~ /^Status:\s+(.+?)$/
              info[:status] = $1.to_s
            end
          end

          # Return the info to build up the results
          info
        end
      end

      def read_guest_additions_version
        output = execute("guestproperty", "get", @uuid, "/VirtualBox/GuestAdd/Version")
        return $1.to_s if output =~ /^Value: (.+?)$/
        return nil
      end

      def read_host_only_interfaces
        execute("list", "hostonlyifs").split("\n\n").collect do |block|
          info = {}

          block.split("\n").each do |line|
            if line =~ /^Name:\s+(.+?)$/
              info[:name] = $1.to_s
            elsif line =~ /^IPAddress:\s+(.+?)$/
              info[:ip] = $1.to_s
            elsif line =~ /^NetworkMask:\s+(.+?)$/
              info[:netmask] = $1.to_s
            end
          end

          info
        end
      end

      def read_mac_address
        execute("showvminfo", @uuid, "--machinereadable").split("\n").each do |line|
          return $1.to_s if line =~ /^macaddress1="(.+?)"$/
        end

        nil
      end

      def read_machine_folder
        execute("list", "systemproperties").split("\n").each do |line|
          if line =~ /^Default machine folder:\s+(.+?)$/i
            return $1.to_s
          end
        end

        nil
      end

      def read_network_interfaces
        nics = {}
        execute("showvminfo", @uuid, "--machinereadable").split("\n").each do |line|
          if line =~ /^nic(\d+)="(.+?)"$/
            adapter = $1.to_i
            type    = $2.to_sym

            nics[adapter] ||= {}
            nics[adapter][:type] = type
          elsif line =~ /^hostonlyadapter(\d+)="(.+?)"$/
            adapter = $1.to_i
            network = $2.to_s

            nics[adapter] ||= {}
            nics[adapter][:hostonly] = network
          elsif line =~ /^bridgeadapter(\d+)="(.+?)"$/
            adapter = $1.to_i
            network = $2.to_s

            nics[adapter] ||= {}
            nics[adapter][:bridge] = network
          end
        end

        nics
      end

      def read_state
        output = execute("showvminfo", @uuid, "--machinereadable")
        if output =~ /^name="<inaccessible>"$/
          return :inaccessible
        elsif output =~ /^VMState="(.+?)"$/
          return $1.to_sym
        end

        nil
      end

      def read_used_ports
        ports = []
        execute("list", "vms").split("\n").each do |line|
          if line =~ /^".+?" \{(.+?)\}$/
            uuid = $1.to_s

            # Ignore our own used ports
            next if uuid == @uuid

            read_forwarded_ports(uuid, true).each do |_, _, hostport, _|
              ports << hostport
            end
          end
        end

        ports
      end

      def set_mac_address(mac)
        execute("modifyvm", @uuid, "--macaddress1", mac)
      end

      def share_folders(folders)
        folders.each do |folder|
          execute("sharedfolder", "add", @uuid, "--name",
                  folder[:name], "--hostpath", folder[:hostpath])
        end
      end

      def ssh_port(expected_port)
        # Look for the forwarded port only by comparing the guest port
        read_forwarded_ports.each do |_, _, hostport, guestport|
          return hostport if guestport == expected_port
        end

        nil
      end

      def start(mode)
        execute("startvm", @uuid, "--type", mode.to_s)
      end

      def suspend
        execute("controlvm", @uuid, "savestate")
      end

      def verify_image(path)
        r = raw("import", path.to_s, "--dry-run")
        return r.exit_code == 0
      end

      def vm_exists?(uuid)
        raw("showvminfo", uuid).exit_code == 0
      end
    end
  end
end
