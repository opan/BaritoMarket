class BlueprintProcessor
  attr_accessor :blueprint_hash, :nodes, :infrastructure_components, :errors, :infrastructure

  def initialize(blueprint_hash, opts = {})
    @blueprint_hash = blueprint_hash
    @nodes = []
    @infrastructure_components = []
    @errors = []
    @infrastructure = Infrastructure.find(@blueprint_hash['infrastructure_id'])

    # Initialize Provisioner
    @sauron_host          = (opts[:sauron_host] || '127.0.0.1:3000')
    @container_host       = (opts[:container_host] || '127.0.0.1')
    @container_host_name  = (opts[:container_host_name] || 'localhost')
    @provisioner          = SauronProvisioner.new(
      @sauron_host,
      @container_host,
      @container_host_name
    )

    # Initialize Bootstrapper
    @chef_repo_dir        = (opts[:chef_repo_dir] || '/opt/chef-repo')
    @bootstrapper         = ChefSoloBootstrapper.new(@chef_repo_dir)

    # Private keys
    @private_keys_dir     = (opts[:private_keys_dir] ||
      "#{Rails.root}/config/private_keys")
    @private_key_name     = opts[:private_key_name]
    @username             = opts[:username]
  end

  def process!
    # Reset nodes and errors
    @nodes = @blueprint_hash['nodes'].dup

    @blueprint_hash['nodes'].each_with_index do |node, seq|
      @infrastructure_components << InfrastructureComponent.add(@infrastructure, node, seq+1)
    end

    @errors = []

    # Provision instances
    @infrastructure.update_provisioning_status('PROVISIONING_STARTED')
    Rails.logger.info "Infrastructure:#{@infrastructure.id} -- Provisioning started"
    if provision_instances!
      @infrastructure.update_provisioning_status('PROVISIONING_FINISHED')
      Rails.logger.info "Infrastructure:#{@infrastructure.id} -- Provisioning finished"
    else
      @infrastructure.update_provisioning_status('PROVISIONING_ERROR')
      Rails.logger.error "Infrastructure:#{@infrastructure.id} -- Provisioning error: #{@errors}"
      return false
    end

    # Bootstrap instances
    @infrastructure.update_provisioning_status('BOOTSTRAP_STARTED')
    Rails.logger.info "Infrastructure:#{@infrastructure.id} -- Bootstrap started"
    if bootstrap_instances!
      @infrastructure.update_provisioning_status('FINISHED')
      Rails.logger.info "Infrastructure:#{@infrastructure.id} -- Bootstrap finished"
    else
      @infrastructure.update_provisioning_status('BOOTSTRAP_ERROR')
      Rails.logger.error "Infrastructure:#{@infrastructure.id} -- Bootstrap error: #{@errors}"
      return false
    end

    # Save consul host
    consul_hosts = fetch_hosts_address_by(@nodes, 'category', 'consul')
    consul_host = (consul_hosts || []).sample
    @infrastructure.update!(consul_host: "#{consul_host}:#{Figaro.env.default_consul_port}")

    return true
  end
  def provision_instances!
    @infrastructure_components.each do |component|
      Rails.logger.info "Infrastructure:#{@infrastructure.id} -- InfrastructureComponent:#{component.id} -- Provisioning #{component.hostname}"
      return false unless provision_instance!(
        component,
        private_key_name: @private_key_name
      )
    end
    return true
  end

  def provision_instance!(component, opts = {})
    success = false

    component.update_status('PROVISIONING_STARTED')
    # Execute provisioning
    res = @provisioner.provision!(
      component.hostname,
      key_pair_name: opts[:private_key_name]
    )
    Rails.logger.info "Infrastructure:#{@infrastructure.id} -- InfrastructureComponent:#{component.id} -- Provisioning #{component.hostname} -- #{res}"

    if res['success'] == true
      component.update_ipaddress(res.dig('data', 'host_ipaddress'))
      component.update_status('PROVISIONING_FINISHED')

      # TODO add key_pair_name column in infrastructure table
      # @infrastructure.key_pair_name = res.dig('data', 'key_pair_name')
      # @infrastructure.save! unless @infrastructure.key_pair_name==res.dig('data', 'key_pair_name')

      success = true
    else
      @errors << { message: res['error'] }
      component.update_status('PROVISIONING_ERROR', @errors.to_s)
    end

    return success
  end

  def bootstrap_instances!
    @infrastructure_components.each do |component|
      Rails.logger.info "Infrastructure:#{@infrastructure.id} -- InfrastructureComponent:#{component.id} -- Bootstrapping #{component.hostname}"
      attrs = generate_bootstrap_attributes(component, @infrastructure_components)
      return false unless bootstrap_instance!(
        component,
        @username,
        private_keys_dir: @private_keys_dir,
        private_key_name: @private_key_name,
        attrs: attrs
      )
    end
    return true
  end

  def bootstrap_instance!(component, username, opts = {})
    success = false

    component.update_status('BOOTSTRAP_STARTED')
    # Get private key file path
    private_key = nil
    if opts[:private_keys_dir] && opts[:private_key_name]
      private_key = File.join(opts[:private_keys_dir], opts[:private_key_name])
    end

    res = @bootstrapper.bootstrap!(
      component.hostname,
      component.ipaddress,
      username,
      private_key: private_key,
      attrs: opts[:attrs]
    )
    Rails.logger.info "Infrastructure:#{@infrastructure.id} -- InfrastructureComponent:#{component.id} -- Bootstrapping #{component.hostname} -- #{res}"

    if res['success'] == true
      success = true
      component.update_attribute(:bootstrap_attribute, opts[:attrs])
      component.update_status('FINISHED')
    else
      @errors << { message: res['error'], log: res['error_log'] }
      component.update_status('BOOTSTRAP_ERROR', @errors.to_s)
    end

    return success
  end

  def generate_bootstrap_attributes(component, infrastructure_components)
    # Fetch consul hosts
    consul_hosts = fetch_hosts_address_by(infrastructure_components, 'category', 'consul')

    case component.category
    when 'consul'
      ChefHelper::ConsulRoleAttributesGenerator.
        new(consul_hosts).
        generate
    when 'barito-flow-consumer'
      kafka_hosts = fetch_hosts_address_by(infrastructure_components, 'category', 'kafka')
      es_host = fetch_hosts_address_by(infrastructure_components, 'category', 'elasticsearch').first
      ChefHelper::BaritoFlowConsumerRoleAttributesGenerator.
        new(@infrastructure.secret_key, kafka_hosts, es_host, consul_hosts).
        generate
    when 'barito-flow-producer'
      kafka_hosts = fetch_hosts_address_by(infrastructure_components, 'category', 'kafka')
      max_tps = TPS_CONFIG[@infrastructure.capacity]['max_tps']
      ChefHelper::BaritoFlowProducerRoleAttributesGenerator.
        new(kafka_hosts, consul_hosts, max_tps: max_tps).
        generate
    when 'elasticsearch'
      ChefHelper::ElasticsearchRoleAttributesGenerator.
        new(consul_hosts).
        generate
    when 'kafka'
      zookeeper_hosts = fetch_hosts_address_by(infrastructure_components, 'category', 'zookeeper')
      kafka_hosts = fetch_hosts_address_by(infrastructure_components, 'category', 'kafka')
      ChefHelper::KafkaRoleAttributesGenerator.
        new(zookeeper_hosts, kafka_hosts, consul_hosts).
        generate
    when 'kibana'
      es_host = fetch_hosts_address_by(infrastructure_components, 'category', 'elasticsearch').first
      ChefHelper::KibanaRoleAttributesGenerator.
        new(es_host, consul_hosts).
        generate
    when 'yggdrasil'
      ChefHelper::YggdrasilRoleAttributesGenerator.
        new.
        generate
    when 'zookeeper'
      host = node['instance_attributes']['host_ipaddress'] || node['name']
      zookeeper_hosts = fetch_hosts_address_by(infrastructure_components, 'category', 'zookeeper')
      ChefHelper::ZookeeperRoleAttributesGenerator.
        new(host, zookeeper_hosts, consul_hosts).
        generate
    else
      {}
    end
  end

  private
    def fetch_hosts_address_by(hosts, filter_type, filter)
      infrastructure_components.
        select{ |component| component.send(filter_type.to_sym) == filter }.
        collect{ |component| component.ipaddress || component.hostname }
    end
end
