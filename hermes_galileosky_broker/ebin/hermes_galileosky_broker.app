{application, 'hermes_galileosky_broker', [
	{description, "Hermes Galileosky broker"},
	{vsn, "c426376+dirty"},
	{modules, ['decmap','galileosky_pusher','galileosky_pusher_sup','galileoskydec','hermes_galileosky_broker','hermes_galileosky_broker_sup']},
	{registered, []},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client]},
	{env, []}
]}.