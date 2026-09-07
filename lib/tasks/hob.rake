namespace :hob do
  desc "Onboard a surface: mint its hob key and set HOB_URL/HOB_ADDR/HOB_KEY on its Coolify app. " \
       "bin/rails \"hob:provision[surface,coolify_app_uuid,clearance=personal,principal=jenner]\" (RESTART=0 to skip the restart)"
  task :provision, [ :surface, :app, :clearance, :principal ] => :environment do |_task, args|
    if args[:surface].blank? || args[:app].blank?
      abort "usage: bin/rails \"hob:provision[surface,coolify_app_uuid,clearance=personal,principal=jenner]\""
    end

    result = Provision.new.call(surface: args[:surface], app: args[:app],
                                clearance: args[:clearance].presence || "personal",
                                principal: args[:principal].presence || "jenner",
                                restart: ENV["RESTART"] != "0")
    puts "#{result.surface}: set #{result.env.join(', ')} on #{result.app}; " \
         "rotated #{result.rotated} old key(s); #{result.restarted ? 'restart queued' : 'not restarted'}"
  end
end
