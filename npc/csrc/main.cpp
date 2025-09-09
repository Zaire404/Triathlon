#include <common.h>
extern void init_monitor(int argc, char *argv[]);
extern void sdb_mainloop();
extern int is_exit_status_bad();
int main(int argc, char *argv[]) {
  for(int i = 0; i < argc; i ++ ) {
    printf("第%d个参数位%s\n",i,argv[i]);
  }
  init_monitor(argc, argv);
  sdb_mainloop();
  return is_exit_status_bad();
}
