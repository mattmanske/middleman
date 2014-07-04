require 'middleman-core/util'

class Middleman::Extensions::AssetHash < ::Middleman::Extension
  option :exts, %w(.jpg .jpeg .png .gif .js .css .otf .woff .eot .ttf .svg), 'List of extensions that get asset hashes appended to them.'
  option :ignore, [], 'Regexes of filenames to skip adding asset hashes to'

  def initialize(app, options_hash={}, &block)
    super

    require 'digest/sha1'
    require 'rack/mock'
    require 'uri'
    require 'middleman-core/middleware/inline_url_rewriter'
  end

  def after_configuration
    # Allow specifying regexes to ignore, plus always ignore apple touch icons
    @ignore = Array(options.ignore) + [/^apple-touch-icon/]

    app.use ::Middleman::Middleware::InlineURLRewriter,
            id: :asset_hash,
            url_extensions: options.exts,
            source_extensions: %w(.htm .html .php .css .js),
            ignore: @ignore,
            middleman_app: app,
            proc: method(:rewrite_url)
  end

  Contract String, Or[String, Pathname], Any => Maybe[String]
  def rewrite_url(asset_path, dirpath, _request_path)
    relative_path = Pathname.new(asset_path).relative?

    full_asset_path = if relative_path
      dirpath.join(asset_path).to_s
    else
      asset_path
    end

    return unless asset_page = app.sitemap.find_resource_by_path(full_asset_path)

    replacement_path = "/#{asset_page.destination_path}"
    replacement_path = Pathname.new(replacement_path).relative_path_from(dirpath).to_s if relative_path
    replacement_path
  end

  # Update the main sitemap resource list
  # @return Array<Middleman::Sitemap::Resource>
  Contract ResourceList => ResourceList
  def manipulate_resource_list(resources)
    @rack_client ||= begin
      rack_app = ::Middleman::Rack.new(app).to_app
      ::Rack::MockRequest.new(rack_app)
    end

    # Process resources in order: binary images and fonts, then SVG, then JS/CSS.
    # This is so by the time we get around to the text files (which may reference
    # images and fonts) the static assets' hashes are already calculated.
    grouped = resources.each_with_object({ scripts: [], svgs: [], other: [] }) do |r, sum|
      key = if %w(.js .css).include? r.ext
        :scripts
      elsif %w(.svg).include? r.ext
        :svg
      else
        :other
      end

      sum[key] << r
    end

    grouped[:other] = grouped[:other].map { |r| manipulate_single_resource(r, @rack_client) }

    other_and_svg = grouped[:other] + grouped[:svgs]

    second_app = ::Middleman::Application do
      @sitemap = ::Middleman::Sitemap::Store::Locked.new(other_and_svg)
    end
    second_client = ::Rack::MockRequest.new(::Middleman::Rack.new(second_app).to_app)
    grouped[:svgs] = grouped[:svgs].map { |r| manipulate_single_resource(r, second_client) }

    everything = grouped[:other] + grouped[:svgs] + grouped[:scripts]

    third_app = ::Middleman::Application do
      @sitemap = ::Middleman::Sitemap::Store::Locked.new(everything)
    end
    third_client = ::Rack::MockRequest.new(::Middleman::Rack.new(third_app).to_app)
    grouped[:scripts] = grouped[:scripts].map { |r| manipulate_single_resource(r, third_client) }

    grouped[:other] + grouped[:svgs] + grouped[:scripts]
  end

  Contract IsA['Middleman::Sitemap::Resource'], ::Rack::MockRequest => Maybe[IsA['Middleman::Sitemap::Resource']]
  def manipulate_single_resource(resource, client)
    return resource unless options.exts.include?(resource.ext)
    return resource if ignored_resource?(resource)
    return resource if resource.ignored?

    # Render through the Rack interface so middleware and mounted apps get a shot
    response = client.get(URI.escape(resource.destination_path),
                          'bypass_inline_url_rewriter_asset_hash' => 'true')

    raise "#{resource.path} should be in the sitemap!" unless response.status == 200

    digest = Digest::SHA1.hexdigest(response.body)[0..7]

    resource.change_destination resource.destination_path.sub(/\.(\w+)$/) { |ext| "-#{digest}#{ext}" }
  end

  Contract IsA['Middleman::Sitemap::Resource'] => Bool
  def ignored_resource?(resource)
    @ignore.any? { |ignore| Middleman::Util.path_match(ignore, resource.destination_path) }
  end
end
