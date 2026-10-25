// SPDX-License-Identifier: GPL-3.0-or-later
//
// cd_reader against a model of hps_io's side of a read: sd_ack rises DELAY clocks after sd_rd,
// one data word every 4 clocks for (blk_cnt+1) x 256 words, then sd_ack falls. The image is a
// pattern: word i of the image is (i * 2654435761) >> 16. Checks the counters, the checksum of
// the first 2,048 words, and the sequential and wrapped LBAs.
#include "Vtb_cdtest.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

double sc_time_stamp() { return 0; }

static uint16_t img_word(uint64_t i) { return (uint16_t)((uint32_t)(i * 2654435761u) >> 16); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_cdtest *t = new Vtb_cdtest;
    const uint64_t img_bytes = 100 * 512 + 7;       // 100 whole blocks and a tail
    const int DELAY = 37;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    t->clear = 0; t->run = 0; t->rnd = 0; t->mounted = 0; t->sd_ack = 0; t->sd_buff_wr = 0;
    tick();
    t->img_size = img_bytes; t->mounted = 1; tick(); t->mounted = 0; tick();
    if (!t->have_image || t->image_blocks != 100) { printf("FAIL mount: blocks %u\n", t->image_blocks); return 1; }

    t->run = 1;
    std::vector<uint32_t> lbas;
    int bad = 0;
    for (int req = 0; req < 8 && !bad; req++) {
        int w = 0;
        while (!t->sd_rd && w++ < 1000) tick();
        if (!t->sd_rd) { printf("FAIL no request %d\n", req); return 1; }
        uint32_t lba = t->sd_lba; int cnt = t->sd_blk_cnt + 1;
        lbas.push_back(lba);
        for (int i = 0; i < DELAY; i++) tick();
        t->sd_ack = 1; tick();
        for (int i = 0; i < cnt * 256; i++) {
            t->sd_buff_dout = img_word((uint64_t)lba * 256 + i);
            t->sd_buff_wr = 1; tick(); t->sd_buff_wr = 0; tick(); tick(); tick();
        }
        t->sd_ack = 0; tick(); tick();
    }
    t->run = 0; tick();
    uint32_t sum = 0;
    for (int i = 0; i < 2048; i++) sum += img_word(i);
    printf("LBAs:"); for (auto l : lbas) printf(" %u", l); printf("\n");
    printf("requests %u words %u latency_max %u latency_sum %u checksum %08X (expected %08X)\n",
           t->requests, t->words, t->latency_max, t->latency_sum, t->checksum, sum);
    uint32_t want[] = {0, 32, 64, 0, 32, 64, 0, 32};   // 100 blocks: 0, 32, 64; 96 + 32 > 100 wraps
    for (int i = 0; i < 8; i++) if (lbas[i] != want[i]) bad = 1;
    if (t->requests != 8 || t->words != 8u * 32 * 256 || t->checksum != sum || bad) { printf("FAIL\n"); return 1; }
    printf("PASS\n");
    delete t;
    return 0;
}
