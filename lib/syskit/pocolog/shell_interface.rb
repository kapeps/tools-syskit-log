require 'roby/interface'

module Syskit::Pocolog
    # Definition of the syskit-specific interface commands
    class ShellInterface < Roby::Interface::CommandLibrary
        attr_reader :replay_manager

        def initialize(app)
            super
            @replay_manager = app.plan.execution_engine.pocolog_replay_manager
            Orocos.load_typekit 'base'
            @time_channel = Orocos::RubyTasks::TaskContext
        end

        def time
            replay_manager.time
        end
        command :time, 'the current replay time', advanced: true
    end
end

Roby::Interface::Interface.subcommand 'replay', Syskit::Pocolog::ShellInterface, 'Commands specific to syskit-pocolog'


