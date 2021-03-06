notice('MODULAR: zabbix-database/database_hiera_override.pp')

$detach_database_plugin = hiera('zabbix-database', undef)
$hiera_dir = '/etc/hiera/plugins'
$plugin_name = 'zabbix-database'
$plugin_yaml = "${plugin_name}.yaml"

if $detach_database_plugin {
  $network_metadata = hiera_hash('network_metadata')
  if ! $network_metadata['vips']['zabbix-database'] {
    fail('Database VIP is not defined')
  }
  $yaml_additional_config = pick($detach_database_plugin['yaml_additional_config'], {})
  #TODO (holser): Redesign parseyaml and is_bool once [MODULES-2462] applied
  $settings_hash       = parseyaml($detach_database_plugin['yaml_additional_config'])

  if is_bool($settings_hash) {
    $settings_hash_real = {}
  } else {
    $settings_hash_real = $settings_hash
  }

  $nodes_hash = hiera('nodes')
  $management_vip = hiera('management_vip')
  $database_vip = pick($settings_hash_real['remote_database'],$network_metadata['vips']['zabbix-database']['ipaddr'])

  #Set database_nodes values
  $database_roles = [ 'primary-zabbix-database', 'zabbix-database' ]
  $database_nodes = get_nodes_hash_by_roles($network_metadata, $database_roles)
  $database_address_map = get_node_to_ipaddr_map_by_network_role($database_nodes, 'mgmt/database')
  $database_nodes_ips = values($database_address_map)
  $database_nodes_names = keys($database_address_map)

  ###################
  $roles = join(hiera('roles'), ',')
  case $roles {
    /primary-zabbix-database/: {
      $primary_database = true
      $primary_controller = true
    }
    /^primary/: {
      $primary_database = false
      $primary_controller = true
    }
    default: {
      $primary_database = false
      $primary_controller = false
    }
  }
  case $roles {
    /zabbix-database/: {
      $corosync_roles = $database_roles
      $deploy_vrouter = false
      $mysql_enabled = true
      $corosync_nodes = $database_nodes
      $colocate_haproxy = 'false'
    }
    default: {
      $mysql_enabled = false
    }
  }
  ###################
  $calculated_content = inline_template('
primary_database: <%= @primary_database %>
database_vip: <%= @database_vip %>
<% if @database_nodes -%>
<% require "yaml" -%>
database_nodes:
<%= YAML.dump(@database_nodes).sub(/--- *$/,"") %>
<% end -%>
mysqld_ipaddresses:
<% if @database_nodes_ips -%>
<%
@database_nodes_ips.each do |databasenode|
%>  - <%= databasenode %>
<% end -%>
<% end -%>
<% if @database_nodes_names -%>
mysqld_names:
<%
@database_nodes_names.each do |databasenode|
%>  - <%= databasenode %>
<% end -%>
<% end -%>
mysql:
  enabled: <%= @mysql_enabled %>
primary_controller: <%= @primary_controller %>
<% if @corosync_nodes -%>
<% require "yaml" -%>
corosync_nodes:
<%= YAML.dump(@corosync_nodes).sub(/--- *$/,"") %>
<% end -%>
<% if @corosync_roles -%>
corosync_roles:
<%
@corosync_roles.each do |crole|
%>  - <%= crole %>
<% end -%>
<% end -%>
<% if @colocate_haproxy -%>
colocate_haproxy: <%= @colocate_haproxy %>
<% end -%>
deploy_vrouter: <%= @deploy_vrouter %>
')

  ###################
  file {'/etc/hiera/override':
    ensure  => directory,
  } ->
  file { "${hiera_dir}/${plugin_yaml}":
    ensure  => file,
    content => "${detach_database_plugin['yaml_additional_config']}\n${calculated_content}\n",
  }

  package {'ruby-deep-merge':
    ensure  => 'installed',
  }
}

