{application, 'hermes_json', [
	{description, "Hermes -> JSON"},
	{vsn, "0.1.0"},
	{modules, ['hermes_json','hermes_json_sup','hermesenc','json_pusher']},
	{registered, []},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client,jsone]},
	{env, []}
]}.