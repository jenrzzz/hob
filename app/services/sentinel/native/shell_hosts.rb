module Sentinel
  module Native
    # shell.hosts: the machines the agent may run commands on.
    class ShellHosts < ShellHandler
      CAPABILITY = {
        "name" => "shell.hosts",
        "description" => "The machines you may run commands on with shell.exec, shell.read, and shell.write. Returns " \
                         "{ hosts: [{ name, login, about, yours }], notice }: `login` is who you are there, `about` is " \
                         "what a person wrote down about the machine (what it is for, what it serves), and `yours` " \
                         "says it is kept for you alone. An empty list means no machine is set up for you.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
      }.freeze

      def call
        hosts = Shells.hosts.map do |row|
          { "name" => row.name, "login" => row.login, "about" => row.about, "yours" => row.agent_id.present? && row.agent_id == Current.principal&.id }.compact
        end
        noticed("hosts" => hosts)
      end
    end
  end
end
