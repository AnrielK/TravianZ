#ifndef MARIADBCORE_H
#define MARIADBCORE_H
/// Runs the MariaDB server exactly like the `mariadbd` binary (blocks for the server's lifetime).
/// Example: {"mariadbd", "--no-defaults", "--datadir=/…", "--socket=/…/m.sock", NULL}
int ov_mariadbd_main(int argc, char **argv);
#endif
