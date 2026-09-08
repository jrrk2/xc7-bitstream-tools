#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "Vsim.h"
#include <verilated.h>
#include "sim_header.h"

extern "C" void litex_sim_init_runtime(long load_start, long save_start);
#if defined(__GNUC__) || defined(__clang__)
extern "C" void litex_sim_user_init(void *vsim) __attribute__((weak));
extern "C" void litex_sim_user_init(void *vsim)
{
    (void)vsim;
}

static void litex_sim_call_user_init(void *vsim)
{
    litex_sim_user_init(vsim);
}
#else
static void litex_sim_call_user_init(void *vsim)
{
    (void)vsim;
}
#endif
extern "C" void litex_sim_dump()
{
}

extern "C" void litex_sim_init(void **out)
{
    Vsim *sim;

    sim = new Vsim;

    litex_sim_init_runtime(0, -1);
    sim_trace[0].signal = &sim->sim_trace;
    litex_sim_register_pads(sim_trace, (char*)"sim_trace", 0);

    sys_clk[0].signal = &sim->sys_clk;
    litex_sim_register_pads(sys_clk, (char*)"sys_clk", 0);

    sys_rst[0].signal = &sim->sys_rst;
    litex_sim_register_pads(sys_rst, (char*)"sys_rst", 0);

    sdcard[0].signal = &sim->sdcard_clk;
    sdcard[1].signal = &sim->sdcard_cmd;
    sdcard[2].signal = &sim->sdcard_data;
    litex_sim_register_pads(sdcard, (char*)"sdcard", 0);

    litex_sim_call_user_init(sim);

    *out = sim;
}
