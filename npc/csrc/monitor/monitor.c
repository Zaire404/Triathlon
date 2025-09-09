#include <common.h>
#include <memory/paddr.h>
void sim_init();
void sdb_set_batch_mode();
void init_difftest(char *ref_so_file, long img_size, int port);
void init_disasm(const char *triple);
void init_sdb();
void init_iringbuf();
static char *log_file = NULL;
static char *diff_so_file = NULL;
static char *img_file = NULL;
static char *elf_file = NULL;
static int difftest_port = 1234;

static long load_img() {
  if (img_file == NULL) {
    printf("No image is given. Use the default build-in image.\n");
    return 4096; // built-in image size
  }
  printf("load file is %s\n",img_file);
  FILE *fp = fopen(img_file, "rb");

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);

  printf("The image is %s, size = %ld\n", img_file, size);

  fseek(fp, 0, SEEK_SET);
  int ret = fread(guest_to_host(MBASE), size, 1, fp);
  assert(ret == 1);

  fclose(fp);
  return size;
}
#include <getopt.h>

static int parse_args(int argc, char *argv[]) {
  const struct option table[] = {
    {"batch"    , 0                 , NULL, 'b'},
    {"log"      , 1                 , NULL, 'l'},
    {"diff"     , 1                 , NULL, 'd'},
    {"port"     , 1                 , NULL, 'p'},
    {"elf"      , 1                 , NULL, 'e'},
    {"help"     , 0                 , NULL, 'h'},
    {0          , 0                 , NULL,  0 },
  }; 
  int o;
  while ( (o = getopt_long(argc, argv, "-bhl:d:p:e:", table, NULL)) != -1) {
    switch (o) {
      case 'b': sdb_set_batch_mode(); break;
      case 'p': sscanf(optarg, "%d", &difftest_port); break;
      case 'l': log_file = optarg; break;
      case 'd': diff_so_file = optarg; break;
      case 'e': elf_file = optarg; break;
      case 1: img_file = optarg; return 0;
      default:
        printf("Usage: %s [OPTION...] IMAGE [args]\n\n", argv[0]);
        printf("\t-b,--batch              run with batch mode\n");
        printf("\t-l,--log=FILE           output log to FILE\n");
        printf("\t-d,--diff=REF_SO        run DiffTest with reference REF_SO\n");
        printf("\t-p,--port=PORT          run DiffTest with port PORT\n");
        printf("\t-e,--elf=file           Load elf File\n");
        printf("\n");
        exit(0);
    }
  }
  return 0;
}

static const uint32_t img [] = {  
  0x00000073,//ecall
  0x30200073,//mret
  0x000a2103,
  0x00100073,
};


void load_builded_img(){
 memcpy(guest_to_host(MBASE), img, sizeof(img));
}

void init_monitor(int argc, char *argv[]) {
    /* Parse arguments. */
    parse_args(argc, argv);
    /*Initialize built-in img*/
    load_builded_img();
    /* Load the image to memory. This will overwrite the built-in image. */
    long img_size = load_img();
    /* Initialize disasm */
    init_disasm("riscv32-pc-linux-gnu");
    /* Initialize the simple debugger. */
    init_sdb();
    /* initial sim */
    sim_init();
    /* Initialize differential testing. */
    init_difftest(diff_so_file, img_size, difftest_port);
    /* Initialize iringbuf*/
    init_iringbuf();
}