{application, 'hermes_galileosky', [
	{description, "Hermes <- Galileosky"},
	{vsn, "0.1.2"},
	{modules, ['crc17','galileo_pacman','hermes_galileosky','hermes_q_pusher','hermes_sup','hermes_worker']},
	{registered, []},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client]},
	{env, []}
]}.