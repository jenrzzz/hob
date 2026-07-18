Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect("ulid" => "ULID")
end
