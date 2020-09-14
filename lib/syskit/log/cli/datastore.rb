require 'roby'
require 'syskit'
require 'thor'

require 'syskit/log'
require 'syskit/log/datastore/normalize'
require 'syskit/log/datastore/import'
require 'syskit/log/datastore/index_build'
require 'tty-progressbar'
require 'pocolog/cli/null_reporter'
require 'pocolog/cli/tty_reporter'

module Syskit::Log
    module CLI
        class Datastore < Thor
            namespace 'datastore'

            class_option :silent, type: :boolean, default: false
            class_option :colors, type: :boolean, default: TTY::Color.color?
            class_option :progress, type: :boolean, default: TTY::Color.color?
            class_option :store, type: :string

            no_commands do
                def create_reporter(
                    format = '',
                    progress: options[:progress],
                    colors: options[:colors],
                    silent: options[:silent],
                    **options
                )
                    if silent
                        Pocolog::CLI::NullReporter.new
                    else
                        Pocolog::CLI::TTYReporter.new(
                            format, progress: progress, colors: colors, **options
                        )
                    end
                end

                def create_pastel
                    Pastel.new(enabled: options[:colors])
                end

                def datastore_path
                    unless (path = options[:store] || ENV['SYSKIT_LOG_STORE'])
                        raise ArgumentError,
                              'you must provide a path to a datastore either '\
                              'with the --store option or through the '\
                              'SYSKIT_LOG_STORE environment variable'
                    end
                    Pathname.new(path)
                end

                def open_store
                    Syskit::Log::Datastore.new(datastore_path.realpath)
                end

                def create_store
                    Syskit::Log::Datastore.create(datastore_path)
                end

                def show_dataset(pastel, store, dataset, long_digest: false)
                    description = dataset.metadata_fetch_all(
                        'description', '<no description>'
                    )
                    digest = store.short_digest(dataset) unless long_digest
                    format = "% #{digest.size}s"
                    description.zip([digest]) do |a, b|
                        puts "#{pastel.bold(format % [b])} #{a}"
                    end
                    metadata = dataset.metadata
                    metadata.each do |k, v|
                        next if k == 'description'

                        if v.size == 1
                            puts "  #{k}: #{v.first}"
                        else
                            puts "  #{k}:"
                            v.each do |value|
                                puts "  - #{value}"
                            end
                        end
                    end
                end

                def format_date(time)
                    time.strftime('%Y-%m-%d')
                end

                def format_time(time)
                    time.strftime('%H:%M:%S.%6N %z')
                end

                def format_duration(time)
                    '%4i:%02i:%02i.%06i' % [
                        Integer(time / 3600),
                        Integer((time % 3600) / 60),
                        Integer(time % 60),
                        Integer((time * 1_000_000) % 1_000_000)
                    ]
                end

                def show_task_objects(objects, name_field_size)
                    format = "      %-#{name_field_size + 1}s %s"

                    stream_sizes = objects.map do |_, stream|
                        stream.size.to_s
                    end
                    stream_size_field_size = stream_sizes.map(&:size).max
                    stream_sizes = stream_sizes.map do |size|
                        "% #{stream_size_field_size}s" % [size]
                    end
                    objects.each_with_index do |(name, stream), i|
                        if stream.empty?
                            puts format % ["#{name}:", 'empty']
                        else
                            interval_lg = stream.interval_lg.map do |t|
                                format_date(t) + ' ' + format_time(t)
                            end
                            duration_lg = format_duration(stream.duration_lg)
                            puts format % [
                                "#{name}:",
                                "#{stream_sizes[i]} samples from #{interval_lg[0]} "\
                                "to #{interval_lg[1]} [#{duration_lg}]"
                            ]
                        end
                    end
                end

                def show_dataset_pocolog(pastel, store, dataset)
                    tasks = dataset.each_task(
                        load_models: false, skip_tasks_without_models: false
                    ).to_a
                    stream_count = dataset.each_pocolog_path.to_a.size
                    puts "  #{tasks.size} oroGen tasks in #{stream_count} streams"
                    tasks.each do |task|
                        ports = task.each_port_stream.to_a
                        properties = task.each_property_stream.to_a
                        puts "    #{task.task_name}[#{task.orogen_model_name}]: "\
                             "#{ports.size} ports and #{properties.size} properties"
                        name_field_size = (
                            ports.map { |name, _| name.size } +
                            properties.map { |name, _| name.size }
                        ).max
                        unless ports.empty?
                            puts '    Ports:'
                            show_task_objects(ports, name_field_size)
                        end
                        unless properties.empty?
                            puts '    Properties:'
                            show_task_objects(properties, name_field_size)
                        end
                    end
                end

                def show_dataset_roby(pastel, store, dataset); end

                # @api private
                #
                # Parse a query

                # @param [String] query query statements of the form VALUE,
                #   KEY=VALUE and KEY~VALUE. The `=` sign matches exactly, while
                #   `~` matches through a regular expression. Entries with no
                #   `=` and `~` signs are returned separately
                #
                # @return [([String],{String=>#===})] a list of implicit
                #   statements (without = and ~) and a list of key to a matching
                #   object.
                def parse_query(*query)
                    implicit = []
                    explicit = query.each_with_object({}) do |kv, matchers|
                        if kv =~ /=/
                            k, v = kv.split("=")
                            matchers[k] = v
                        elsif kv =~ /~/
                            k, v = kv.split("~")
                            matchers[k] = /#{v}/
                        else # assume this is a digest
                            implicit << kv
                        end
                    end
                    [implicit, explicit]
                end

                # Resolve the list of datasets that match the given query
                #
                # @param [Datastore] store the datastore whose datasets are being
                #   resolved
                # @param query (see #parse_query)
                #
                # @return [[Datastore]] matching datastores
                def resolve_datasets(store, *query)
                    return store.each_dataset if query.empty?

                    implicit, matchers = parse_query(*query)
                    if (digest = implicit.first)
                        Syskit::Log::Datastore::Dataset
                            .validate_encoded_short_digest(digest)
                        matchers["digest"] = /^#{digest}/
                    end

                    store.each_dataset.find_all do |dataset|
                        all_metadata = { "digest" => [dataset.digest] }
                                       .merge(dataset.metadata)
                        all_metadata.any? do |key, values|
                            if (v_match = matchers[key])
                                values.any? { |v| v_match === v }
                            end
                        end
                    end
                end
            end

            desc 'normalize PATH [--out OUTPUT]', 'normalizes a data stream into a format that is suitable for the other log management commands to work'
            method_option :out, desc: 'output directory (defaults to a normalized/ folder under the source folder)',
                default: 'normalized'
            method_option :override, desc: 'whether existing files in the output directory should be overriden',
                type: :boolean, default: false

            def normalize(path)
                path = Pathname.new(path).realpath
                output_path = Pathname.new(options['out']).expand_path(path)
                output_path.mkpath

                paths = Syskit::Log.logfiles_in_dir(path)
                bytes_total = paths.inject(0) do |total, path|
                    total + path.size
                end
                reporter = create_reporter(
                    '|:bar| :current_byte/:total_byte :eta (:byte_rate/s)',
                    total: bytes_total
                )

                begin
                    Syskit::Log::Datastore.normalize(paths, output_path: output_path, reporter: reporter)
                ensure reporter.finish
                end
            end

            desc 'import PATH [DESCRIPTION]',
                 'normalize and import a raw dataset into a syskit-pocolog datastore'
            method_option :auto, desc: 'import all datasets under PATH',
                                 type: :boolean, default: false
            method_option :force, desc: 'overwrite existing datasets',
                                  type: :boolean, default: false
            method_option :min_duration, desc: 'skip datasets whose duration is lower '\
                                               'than this (in seconds)',
                                         type: :numeric, default: 60
            method_option :tags, desc: 'tags to be added to the dataset',
                                 type: :array, default: []
            method_option :metadata, desc: 'metadata values as key=value pairs',
                                     type: :array, default: []
            def import(root_path, description = nil)
                root_path = Pathname.new(root_path).realpath
                if options[:auto]
                    paths = []
                    root_path.find do |p|
                        is_raw_dataset =
                            p.directory? &&
                            Pathname.enum_for(:glob, p + '*-events.log').any? { true } &&
                            Pathname.enum_for(:glob, p + '*.0.log').any? { true }
                        if is_raw_dataset
                            paths << p
                            Find.prune
                        end
                    end
                else
                    paths = [root_path]
                end

                reporter = create_reporter
                datastore = create_store

                metadata = {}
                metadata['description'] = description if description
                metadata['tags'] = options[:tags]
                options[:metadata].each do |pair|
                    k, v = pair.split('=')
                    unless v
                        raise ArgumentError,
                              'expected key=value pair as argument to '\
                              "--metadata but got '#{pair}'"
                    end
                    (metadata[k] ||= []) << v
                end

                paths.each do |p|
                    reporter.title "Processing #{p}"

                    last_import_digest, last_import_time =
                        Syskit::Log::Datastore::Import.find_import_info(p)
                    already_imported = last_import_digest &&
                                       datastore.has?(last_import_digest)
                    if already_imported && !options[:force]
                        reporter.info(
                            "#{p} already seem to have been imported as "\
                            "#{last_import_digest} at #{last_import_time}. Give "\
                            '--force to import again'
                        )
                        next
                    end

                    datastore.in_incoming do |core_path, cache_path|
                        importer = Syskit::Log::Datastore::Import.new(datastore)
                        dataset = importer.normalize_dataset(
                            p, core_path, cache_path: cache_path,
                                          reporter: reporter
                        )
                        metadata.each { |k, v| dataset.metadata_set(k, *v) }
                        dataset.metadata_write_to_file
                        stream_duration = dataset.each_pocolog_stream
                                                 .map(&:duration_lg)
                                                 .max
                        stream_duration ||= 0

                        if already_imported
                            # --force is implied as otherwise we would have
                            # skipped earlier
                            reporter.info(
                                "#{p} seem to have already been imported but --force "\
                                'is given, overwriting'
                            )
                            datastore.delete(last_import_digest)
                        end

                        if stream_duration >= options[:min_duration]
                            begin
                                importer.move_dataset_to_store(
                                    p, dataset, force: options[:force],
                                                reporter: reporter
                                )
                            rescue Syskit::Log::Datastore::Import::DatasetAlreadyExists
                                reporter.info(
                                    "#{p} already seem to have been imported as "\
                                    "#{dataset.compute_dataset_digest}. Give "\
                                    '--force to import again'
                                )
                            end
                        else
                            reporter.info(
                                "#{p} lasts only %.1fs, ignored" % [stream_duration]
                            )
                        end
                    end
                end
            end

            desc 'index [DATASETS]', 'refreshes or rebuilds (with --force) the datastore indexes'
            method_option :force, desc: 'force rebuilding even indexes that look up-to-date',
                type: :boolean, default: false
            def index(*datasets)
                store = open_store
                datasets = resolve_datasets(store, *datasets)
                reporter = create_reporter
                datasets.each do |d|
                    reporter.title "Processing #{d.compute_dataset_digest}"
                    Syskit::Log::Datastore.index_build(
                        store, d, force: options[:force], reporter: reporter
                    )
                end
            end

            desc 'path [QUERY]', 'list path to datasets'
            method_option :long_digests,
                          desc: 'display digests in full, instead of shortening them',
                          type: :boolean, default: false
            def path(*query)
                store = open_store
                datasets = resolve_datasets(store, *query)
                datasets.each do |dataset|
                    digest =
                        if options[:long_digests]
                            dataset.digest
                        else
                            store.short_digest(dataset)
                        end

                    puts "#{digest} #{dataset.dataset_path}"
                end
            end

            desc 'list [QUERY]', 'list datasets and their information'
            method_option :digest, desc: 'only show the digest and no other information (for scripting)',
                type: :boolean, default: false
            method_option :long_digests, desc: 'display digests in full form, instead of shortening them',
                type: :boolean, default: false
            method_option :pocolog, desc: 'show detailed information about the pocolog streams in the dataset(s)',
                type: :boolean, default: false
            method_option :roby, desc: 'show detailed information about the Roby log in the dataset(s)',
                type: :boolean, default: false
            method_option :all, desc: 'show all available information (implies --pocolog and --roby)',
                aliases: 'a', type: :boolean, default: false
            def list(*query)
                store = open_store
                datasets = resolve_datasets(store, *query)

                pastel = create_pastel
                datasets.each do |dataset|
                    if options[:digest]
                        if options[:long_digests]
                            puts dataset.digest
                        else
                            puts store.short_digest(dataset)
                        end
                    else
                        show_dataset(pastel, store, dataset, long_digest: options[:long_digests])
                        if options[:all] || options[:roby]
                            show_dataset_roby(pastel, store, dataset)
                        end
                        if options[:all] || options[:pocolog]
                            show_dataset_pocolog(pastel, store, dataset)
                        end
                    end
                end
            end

            desc 'metadata [QUERY] [--set=KEY=VALUE KEY=VALUE|--get=KEY]',
                'sets or gets metadata values for a dataset or datasets'
            method_option :set, desc: 'the key=value associations to set',
                type: :array
            method_option :get, desc: 'the keys to get',
                type: :array, lazy_default: []
            method_option :long_digest, desc: 'display digests in full form, instead of shortening them',
                type: :boolean, default: false
            def metadata(*query)
                if !options[:get] && !options[:set]
                    raise ArgumentError, "provide either --get or --set"
                elsif options[:get] && options[:set]
                    raise ArgumentError, "cannot provide both --get and --set at the same time"
                end

                store = open_store
                datasets = resolve_datasets(store, *query)

                digest_to_s =
                    if options[:long_digest]
                        ->(d) { d.digest }
                    else
                        store.method(:short_digest)
                    end

                if options[:set]
                    setters = Hash.new
                    options[:set].map do |arg|
                        key, value = arg.split('=')
                        if !value
                            raise ArgumentError, "metadata setters need to be specified as key=value (got #{arg})"
                        end
                        (setters[key] ||= Set.new) << value
                    end

                    datasets.each do |set|
                        setters.each do |k, v|
                            set.metadata_set(k, *v)
                        end
                        set.metadata_write_to_file
                    end
                elsif options[:get].empty?
                    datasets.each do |set|
                        metadata = set.metadata.map { |k, v| [k, v.to_a.sort.join(",")] }.
                            sort_by(&:first).
                            map { |k, v| "#{k}=#{v}" }.
                            join(" ")
                        puts "#{digest_to_s[set]} #{metadata}"
                    end
                else
                    datasets.each do |set|
                        metadata = options[:get].map do |k, v|
                            [k, set.metadata_fetch_all(k, "<unset>")]
                        end
                        metadata = metadata.map { |k, v| "#{k}=#{v.to_a.sort.join(",")}" }.
                            join(" ")
                        puts "#{digest_to_s[set]} #{metadata}"
                    end
                end
            end
        end
    end
end

