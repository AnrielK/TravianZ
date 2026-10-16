#ifndef PHPCORE_H
#define PHPCORE_H
/// Runs PHP exactly like the `php` command line tool (blocks until it exits).
/// Example: {"php", "-S", "127.0.0.1:8080", "-t", "/path/to/game", NULL}
int php_cli_main(int argc, char *argv[]);
#endif
