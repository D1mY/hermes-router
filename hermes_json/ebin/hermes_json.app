{application, 'hermes_json', [
	{description, "Hermes -> JSON"},
	{vsn, "b5b7b40+dirty"},
	{modules, ['hermes_json','hermes_json_sup','hermesenc','json_pusher','json_pusher_sup']},
	{registered, [hermes_json_sup]},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client,jsx]},
	{mod, {hermes_json, []}},
	{env, []}
]}.