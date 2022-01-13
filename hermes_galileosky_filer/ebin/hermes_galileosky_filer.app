{application, 'hermes_galileosky_filer', [
	{description, "Hermes Galileosky filer"},
	{vsn, "0.1.0"},
	{modules, ['galileosky_dump','hermes_galileosky_filer','hermes_galileosky_filer_sup']},
	{registered, []},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client]},
	{env, []}
]}.