module Syskit::Pocolog
    module Plugin
        def self.setup(app)
            Pocolog.logger = Syskit::Pocolog.logger
            manager = Orocos::RubyTasks::ProcessManager.new(app.default_loader)
            Syskit.conf.register_process_server('pocolog', manager, app.log_dir)
        end

        # This hooks into the network generation to deploy all tasks using
        # replay streams
        def self.override_all_deployments_by_replay_streams(streams)
            streams_group = streams.to_deployment_group
            Syskit::NetworkGeneration::Engine.register_system_network_postprocessing do |system_network_generator|
                system_network_generator.plan.find_local_tasks(Syskit::TaskContext).each do |task|
                    task.requirements.reset_deployment_selection
                    task.requirements.use_deployment_group(streams_group)
                end
            end
        end
    end
end

