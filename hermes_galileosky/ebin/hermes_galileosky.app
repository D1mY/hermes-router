{application, 'hermes_galileosky', [
	{description, "Hermes Galileosky server"},
	{vsn, "f1a2b2e+dirty"},
	{modules, ['crc17','galileo_pacman','hermes_accept_sup','hermes_galileosky','hermes_galileosky_sup','hermes_q_pusher','hermes_worker']},
	{registered, [hermes_galileosky_sup]},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client]},
	{mod, {hermes_galileosky, []}},
	{env, []}
]}.