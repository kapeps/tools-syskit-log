require 'test_helper'
require 'syskit/pocolog/cli'

module Syskit::Pocolog
    describe CLI do
        attr_reader :root_path, :datastore_path, :datastore
        before do
            @root_path = Pathname.new(Dir.mktmpdir)
            move_logfile_path((root_path + "logs" + "test").to_s)
            @datastore_path = root_path + "datastore"
            datastore_path.mkpath
            @datastore = Datastore.new(datastore_path)
        end

        after do
            root_path.rmtree
        end

        # Helper method to call a CLI subcommand
        def call_cli(*args, silent: true)
            extra_args = Array.new
            if silent
                extra_args << '--silent'
            end
            CLI.start([*args, *extra_args], debug: true)
        end

        describe "#auto_import" do
            it "creates the datastore path" do
                datastore_path.rmtree
                call_cli('auto-import', datastore_path.to_s, root_path.to_s)
                assert datastore_path.exist?
            end
            it "auto-imports any directory that looks like a raw dataset" do
                create_logfile('test.0.log') {}
                FileUtils.touch logfile_path('test-events.log')
                incoming_path = datastore_path + 'incoming' + '0'
                flexmock(Import).new_instances.should_receive(:normalize_dataset).
                    with(logfile_pathname, incoming_path, silent: true).
                    once.pass_thru
                flexmock(Import).new_instances.should_receive(:move_dataset_to_store).
                    with(logfile_pathname, ->(s) { s.dataset_path == incoming_path }, silent: true).
                    once.pass_thru

                call_cli('auto-import', '--min-duration=0', datastore_path.to_s, logfile_pathname.dirname.to_s, silent: true)
                digest, time = Import.find_import_info(logfile_pathname)
                assert datastore.has?(digest)
            end
            it "ignores datasets that have already been imported" do
                create_logfile('test.0.log') do
                    create_logfile_stream 'test', metadata: Hash['rock_task_name' => 'task', 'rock_task_object_name' => 'port']
                    write_logfile_sample Time.now, Time.now, 10
                    write_logfile_sample Time.now + 10, Time.now + 1, 20
                end
                FileUtils.touch logfile_path('test-events.log')
                call_cli('auto-import', '--min-duration=0', datastore_path.to_s, logfile_pathname.dirname.to_s, silent: true)
                flexmock(Import).new_instances.should_receive(:normalize_dataset).
                    never
                flexmock(Import).new_instances.should_receive(:move_dataset_to_store).
                    never
                _out, err = capture_io do
                    call_cli('auto-import', '--min-duration=0', datastore_path.to_s, logfile_pathname.dirname.to_s, silent: false)
                end
                assert_match /#{logfile_pathname} already seem to have been imported as .*Give --force/,
                    err
            end
            it "processes datasets that have already been imported if --force is given" do
                create_logfile('test.0.log') do
                    create_logfile_stream 'test', metadata: Hash['rock_task_name' => 'task', 'rock_task_object_name' => 'port']
                    write_logfile_sample Time.now, Time.now, 10
                    write_logfile_sample Time.now + 10, Time.now + 1, 20
                end
                FileUtils.touch logfile_path('test-events.log')
                call_cli('auto-import', '--min-duration=0', datastore_path.to_s, logfile_pathname.dirname.to_s, silent: true)
                flexmock(Import).new_instances.should_receive(:normalize_dataset).
                    once.pass_thru
                flexmock(Import).new_instances.should_receive(:move_dataset_to_store).
                    once.pass_thru
                _out, err = capture_io do
                    call_cli('auto-import', '--min-duration=0', '--force', datastore_path.to_s, logfile_pathname.dirname.to_s, silent: false)
                end
                assert_match /#{logfile_pathname} seem to have already been imported but --force is given, overwriting/,
                    err
            end
            it "ignores an empty dataset if --min-duration is non-zero" do
                create_logfile('test.0.log') {}
                FileUtils.touch logfile_path('test-events.log')
                incoming_path = datastore_path + 'incoming' + '0'
                flexmock(Import).new_instances.should_receive(:normalize_dataset).
                    with(logfile_pathname, incoming_path, silent: true).
                    once.pass_thru
                flexmock(Import).new_instances.should_receive(:move_dataset_to_store).
                    never

                call_cli('auto-import', '--min-duration=1', datastore_path.to_s, logfile_pathname.dirname.to_s, silent: true)
            end
            it "ignores datasets whose logical duration is lower than --min-duration" do
                create_logfile('test.0.log') do
                    create_logfile_stream 'test', metadata: Hash['rock_task_name' => 'task', 'rock_task_object_name' => 'port']
                    write_logfile_sample Time.now, Time.now, 10
                    write_logfile_sample Time.now + 10, Time.now + 1, 20
                end
                FileUtils.touch logfile_path('test-events.log')
                incoming_path = datastore_path + 'incoming' + '0'
                flexmock(Import).new_instances.should_receive(:normalize_dataset).
                    with(logfile_pathname, incoming_path, silent: false).
                    once.pass_thru
                flexmock(Import).new_instances.should_receive(:move_dataset_to_store).
                    never

                _out, err = capture_io do
                    call_cli('auto-import', '--min-duration=5', datastore_path.to_s, logfile_pathname.dirname.to_s, silent: false)
                end
                assert_match /#{logfile_pathname} lasts only 1.0s, ignored/, err
            end
        end

        describe "#import" do
            it "imports a single dataset into the store" do
                flexmock(Syskit::Pocolog).should_receive(:import).
                    with(->(store) { store.datastore_path == datastore_path }, logfile_pathname, force: false, silent: true).
                    once.pass_thru

                call_cli('import', datastore_path.to_s, logfile_pathname.to_s, silent: true)
            end
        end

        describe "#normalize" do
            it "normalizes the logfiles in the input directory into the directory provided as 'out'" do
                create_logfile('test.0.log') {}
                out_path = root_path + "normalized"
                flexmock(Syskit::Pocolog).should_receive(:normalize).
                    with([logfile_pathname('test.0.log')], hsh(output_path: out_path)).
                    once.pass_thru
                call_cli('normalize', logfile_pathname.to_s, "--out=#{out_path}", silent: true)
            end
            it "reports progress without --silent" do
                create_logfile('test.0.log') {}
                out_path = root_path + "normalized"
                flexmock(Syskit::Pocolog).should_receive(:normalize).
                    with([logfile_pathname('test.0.log')], hsh(output_path: out_path)).
                    once.pass_thru
                capture_io do
                    call_cli('normalize', logfile_pathname.to_s, "--out=#{out_path}", silent: false)
                end
            end
        end
    end
end
