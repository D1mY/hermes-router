{application, 'hermes_galileosky_broker', [
	{description, "Hermes Galileosky broker"},
	{vsn, "0.1.0"},
	{modules, ['decmap','galileosky_pusher','galileoskydec','hermes_galileosky_broker','hermes_galileosky_broker_sup']},
	{registered, []},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client]},
	{env, []}
]}.