require 'test_helper'
require 'syskit/log/datastore/import'
require 'tmpdir'
require 'timecop'

module Syskit::Log
    class Datastore
        describe Import do
            attr_reader :root_path, :datastore_path, :import, :datastore

            before do
                @root_path = Pathname.new(Dir.mktmpdir)
                @datastore_path = root_path + 'datastore'
                datastore_path.mkpath
                @datastore = Datastore.create(datastore_path)
                @import = Import.new(datastore)
            end
            after do
                root_path.rmtree
            end

            describe "#prepare_import" do
                it "lists the pocolog files that should be copied, in normalized order" do
                    FileUtils.touch(file0_1 = logfile_pathname('file0.1.log'))
                    FileUtils.touch(file0_0 = logfile_pathname('file0.0.log'))
                    FileUtils.touch(file1_0 = logfile_pathname('file1.0.log'))
                    assert_equal [[file0_0, file0_1, file1_0], [], nil, []], import.prepare_import(logfile_pathname)
                end
                it "lists the test files that should be copied" do
                    FileUtils.touch(path = logfile_pathname('file0.txt'))
                    assert_equal [[], [path], nil, []], import.prepare_import(logfile_pathname)
                end
                it "lists the Roby log files that should be copied" do
                    FileUtils.touch(path = logfile_pathname('test-events.log'))
                    assert_equal [[], [], path, []], import.prepare_import(logfile_pathname)
                end
                it "raises if more than one file looks like a roby log file" do
                    FileUtils.touch(logfile_pathname('test-events.log'))
                    FileUtils.touch(logfile_pathname('test2-events.log'))
                    e = assert_raises(ArgumentError) do
                        import.prepare_import(logfile_pathname)
                    end
                    assert_match "more than one Roby event log found", e.message
                end
                it "ignores pocolog's index files" do
                    FileUtils.touch(path = logfile_pathname('file0.1.log'))
                    FileUtils.touch(logfile_pathname('file0.1.idx'))
                    assert_equal [[path], [], nil, []], import.prepare_import(logfile_pathname)
                end
                it "ignores Roby index files" do
                    FileUtils.touch(path = logfile_pathname('test-events.log'))
                    FileUtils.touch(logfile_pathname('test-index.log'))
                    assert_equal [[], [], path, []], import.prepare_import(logfile_pathname)
                end
                it "lists unrecognized files" do
                    FileUtils.touch(path = logfile_pathname('not_matching'))
                    assert_equal [[], [], nil, [path]], import.prepare_import(logfile_pathname)
                end
                it "lists unrecognized directories" do
                    (path = logfile_pathname('not_matching')).mkpath
                    assert_equal [[], [], nil, [path]], import.prepare_import(logfile_pathname)
                end
            end

            describe "#import" do
                before do
                    create_logfile 'test.0.log' do
                        create_logfile_stream 'test',
                            metadata: Hash['rock_task_name' => 'task0', 'rock_task_object_name' => 'port']
                    end
                    FileUtils.touch logfile_pathname('test.txt')
                    FileUtils.touch logfile_pathname('test-events.log')
                    FileUtils.touch logfile_pathname('not_recognized_file')
                    logfile_pathname('not_recognized_dir').mkpath
                    FileUtils.touch logfile_pathname('not_recognized_dir', 'test')
                end

                def tty_reporter
                    Pocolog::CLI::TTYReporter.new('', color: false, progress: false)
                end

                it 'can import an empty folder' do
                    Dir.mktmpdir do |dir|
                        import.import(Pathname.new(dir))
                    end
                end

                it "moves the results under the dataset's ID" do
                    flexmock(Dataset).new_instances.should_receive(:compute_dataset_digest).
                        and_return('ABCDEF')
                    import_dir = import.import(logfile_pathname)
                    assert_equal(datastore_path + 'core' + 'ABCDEF', import_dir)
                end
                it 'raises if the target dataset ID already exists' do
                    flexmock(Dataset).new_instances.should_receive(:compute_dataset_digest).
                        and_return('ABCDEF')
                    (datastore_path + 'core' + 'ABCDEF').mkpath
                    assert_raises(Import::DatasetAlreadyExists) do
                        import.import(logfile_pathname)
                    end
                end
                it "replaces the current dataset by the new one if the ID already exists but 'force' is true" do
                    digest = 'ABCDEF'
                    flexmock(Dataset)
                        .new_instances.should_receive(:compute_dataset_digest)
                        .and_return(digest)
                    (datastore_path + 'core' + digest).mkpath
                    FileUtils.touch (datastore_path + 'core' + digest + 'file')
                    out, = capture_io do
                        import.import(
                            logfile_pathname, reporter: tty_reporter, force: true
                        )
                    end
                    assert_match /Replacing existing dataset #{digest} with new one/, out
                    assert !(datastore_path + digest + 'file').exist?
                end
                it 'reports its progress' do
                    # This is not really a unit test. It just exercises the code
                    # path that reports progress, but checks nothing except the lack
                    # of exceptions
                    capture_io do
                        import.import(logfile_pathname)
                    end
                end
                it 'normalizes the pocolog logfiles' do
                    expected_normalize_args = hsh(
                        output_path: datastore_path + 'incoming' + '0' + 'core' + 'pocolog',
                        index_dir: datastore_path + 'incoming' + '0' + 'cache' + 'pocolog')

                    flexmock(Syskit::Log::Datastore).should_receive(:normalize).
                        with([logfile_pathname('test.0.log')], expected_normalize_args).once.
                        pass_thru
                    import_dir = import.import(logfile_pathname)
                    assert (import_dir + 'pocolog' + 'task0::port.0.log').exist?
                end
                it "copies the text files" do
                    import_dir = import.import(logfile_pathname)
                    assert logfile_pathname('test.txt').exist?
                    assert (import_dir + 'text' + 'test.txt').exist?
                end
                it "copies the roby log files into roby-events.log" do
                    import_dir = import.import(logfile_pathname)
                    assert logfile_pathname('test-events.log').exist?
                    assert (import_dir + 'roby-events.log').exist?
                end
                it "copies the unrecognized files" do
                    import_dir = import.import(logfile_pathname)

                    assert logfile_pathname('not_recognized_file').exist?
                    assert logfile_pathname('not_recognized_dir').exist?
                    assert logfile_pathname('not_recognized_dir', 'test').exist?

                    assert (import_dir + 'ignored' + 'not_recognized_file').exist?
                    assert (import_dir + 'ignored' + 'not_recognized_dir').exist?
                    assert (import_dir + 'ignored' + 'not_recognized_dir' + 'test').exist?
                end
                it "imports the Roby metadata" do
                    roby_metadata = Array[Hash['app_name' => 'test']]
                    logfile_pathname("info.yml").open('w') do |io|
                        YAML.dump(roby_metadata, io)
                    end
                    import_dir = import.import(logfile_pathname)
                    assert_equal Hash['roby:app_name' => Set['test']], Dataset.new(import_dir).metadata
                end
                it "ignores the Roby metadata if it cannot be loaded" do
                    logfile_pathname("info.yml").open('w') do |io|
                        io.write "%invalid_yaml"
                    end

                    import_dir = nil
                    _out, err = capture_io do
                        import_dir = import.import(logfile_pathname)
                    end
                    assert_match /failed to load Roby metadata/, err
                    assert_equal Hash[], Dataset.new(import_dir).metadata
                end
            end

            describe "#find_import_info" do
                it "returns nil for a directory that has not been imported" do
                    assert_nil Import.find_import_info(logfile_pathname)
                end

                it "returns the import information of an imported directory" do
                    path = Timecop.freeze(base_time = Time.now) do
                        import.import(logfile_pathname)
                    end
                    digest, time = Import.find_import_info(logfile_pathname)
                    assert_equal digest, path.basename.to_s
                    assert_equal base_time, time
                end
            end
        end
    end
end
