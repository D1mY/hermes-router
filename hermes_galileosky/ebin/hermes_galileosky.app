{application, 'hermes_galileosky', [
	{description, "Hermes Galileosky server"},
	{vsn, "61a8369+dirty"},
	{modules, ['crc17','galileo_pacman','galileo_pacman_sup','hermes_accept_sup','hermes_galileosky','hermes_galileosky_sup','hermes_q_pusher','hermes_q_pusher_sup','hermes_worker']},
	{registered, [hermes_galileosky_sup]},
	{applications, [kernel,stdlib,rabbit_common,rabbit,amqp_client]},
	{mod, {hermes_galileosky, []}},
	{env, []}
]}.