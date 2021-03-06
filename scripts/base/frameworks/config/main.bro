##! The configuration framework provides a way to change Bro options
##! (as specified by the "option" keyword) at runtime. It also logs runtime
##! changes to options to config.log.

@load base/frameworks/cluster

module Config;

export {
	## The config logging stream identifier.
	redef enum Log::ID += { LOG };

	## Represents the data in config.log.
	type Info: record {
		## Timestamp at which the configuration change occured.
		ts: time &log;
		## ID of the value that was changed.
		id: string &log;
		## Value before the change.
		old_value: string &log;
		## Value after the change.
		new_value: string &log;
		## Optional location that triggered the change.
		location: string &optional &log;
	};

	## Event that can be handled to access the :bro:type:`Config::Info`
	## record as it is sent on to the logging framework.
	global log_config: event(rec: Info);

	## Broker topic for announcing new configuration values. Sending new_value,
	## peers can send configuration changes that will be distributed across
	## the entire cluster.
	const change_topic = "bro/config/change";

	## This function is the config framework layer around the lower-level
	## :bro:see:`Option::set` call. Config::set_value will set the configuration
	## value for all nodes in the cluster, no matter where it was called. Note
	## that :bro:see:`Option::set` does not distribute configuration changes
	## to other nodes.
	##
	## ID: The ID of the option to update.
	##
	## val: The new value of the option.
	##
	## location: Optional parameter detailing where this change originated from.
	##
	## Returns: true on success, false when an error occurs.
	global set_value: function(ID: string, val: any, location: string &default = "" &optional): bool;
}

@if ( Cluster::is_enabled() )
type OptionCacheValue: record {
	val: any;
	location: string;
};

global option_cache: table[string] of OptionCacheValue;

event bro_init()
	{
	Broker::subscribe(change_topic);
	}

event Config::cluster_set_option(ID: string, val: any, location: string)
	{
@if ( Cluster::local_node_type() == Cluster::MANAGER )
	option_cache[ID] = OptionCacheValue($val=val, $location=location);
@endif
	Option::set(ID, val, location);
	}

function set_value(ID: string, val: any, location: string &default = "" &optional): bool
	{
	local cache_val: any;
	# First cache value in case setting it succeeds and we have to store it.
	if ( Cluster::local_node_type() == Cluster::MANAGER )
		cache_val = copy(val);
	# First try setting it locally - abort if not possible.
	if ( ! Option::set(ID, val, location) )
		return F;
	# If setting worked, copy the new value into the cache on the manager
	if ( Cluster::local_node_type() == Cluster::MANAGER )
		option_cache[ID] = OptionCacheValue($val=cache_val, $location=location);

	# If it turns out that it is possible - send it to everyone else to apply.
	Broker::publish(change_topic, Config::cluster_set_option, ID, val, location);

	if ( Cluster::local_node_type() != Cluster::MANAGER )
		{
		Broker::relay(change_topic, change_topic, Config::cluster_set_option, ID, val, location);
		}
	return T;
	}
@else
# Standalone implementation
function set_value(ID: string, val: any, location: string &default = "" &optional): bool
	{
	return Option::set(ID, val, location);
	}
@endif

@if ( Cluster::is_enabled() && Cluster::local_node_type() == Cluster::MANAGER )
# Handling of new worker nodes.
event Cluster::node_up(name: string, id: string) &priority=-10
	{
	# When a node connects, send it all current Option values.
	if ( name in Cluster::nodes )
		for ( ID in option_cache )
			Broker::publish(Cluster::node_topic(name), Config::cluster_set_option, ID, option_cache[ID]$val, option_cache[ID]$location);
	}
@endif


function format_value(value: any) : string
	{
	local tn = type_name(value);
	local part: string_vec = vector();
	if ( /^set/ in tn )
		{
		local it: set[bool] = value;
		for ( sv in it )
			part += cat(sv);
		return join_string_vec(part, ",");
		}
	else if ( /^vector/ in tn )
		{
		local vit: vector of any = value;
		for ( i in vit )
			part += cat(vit[i]);
		return join_string_vec(part, ",");
		}
	else if ( tn == "string" )
		return value;

	return cat(value);
	}

function config_option_changed(ID: string, new_value: any, location: string): any
	{
	local log = Info($ts=network_time(), $id=ID, $old_value=format_value(lookup_ID(ID)), $new_value=format_value(new_value));
	if ( location != "" )
		log$location = location;
	Log::write(LOG, log);
	return new_value;
	}

event bro_init() &priority=10
	{
	Log::create_stream(LOG, [$columns=Info, $ev=log_config, $path="config"]);

	# Limit logging to the manager - everyone else just feeds off it.
@if ( !Cluster::is_enabled() || Cluster::local_node_type() == Cluster::MANAGER )
	# Iterate over all existing options and add ourselves as change handlers
	# with a low priority so that we can log the changes.
	local gids = global_ids();
	for ( i in gids )
		{
		if ( ! gids[i]$option_value )
			next;

		Option::set_change_handler(i, config_option_changed, -100);
		}
@endif
	}
