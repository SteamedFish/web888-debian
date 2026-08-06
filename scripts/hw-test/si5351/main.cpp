// Minimal Si5351 init for Web-888 driver HW gate.
// Replicates the stock userspace clock setup from RaspSDR/server zynq/peri.cpp:
//   init(crystal_load=0pF, ref=24.576 MHz) -> set_freq(66.6666 MHz, CLK0) -> 8 mA
// Purpose: clock the PL RX/status domain so /dev/zynqsdr GET_SIGNATURE/GET_DNA
// and the RX data path can be validated before the full websdr build (M5).
#include <cstdio>
#include "LinuxInterface.h"
#include "si5351.h"

int main(int argc, char **argv)
{
    const double adc_clock_hz = 66.6666e6;   // ADC_CLOCK_NOM per init/clk.h comment
    const uint32_t ref_hz     = 24576000;    // XREF_FREQ per stock analysis

    I2CInterface *i2c = new LinuxInterface(0, 0x60);
    Si5351 *si = new Si5351(0x60, i2c);

    bool found = si->init(SI5351_CRYSTAL_LOAD_0PF, ref_hz, 0);
    printf("si5351 init: %s\n", found ? "chip found" : "NOT FOUND");
    if (!found)
        return 1;

    int ret = si->set_freq((uint64_t)(adc_clock_hz * 100), SI5351_CLK0);
    si->drive_strength(SI5351_CLK0, SI5351_DRIVE_8MA);
    printf("si5351 CLK0 = %.4f MHz, set_freq ret=%d\n", adc_clock_hz / 1e6, ret);
    return ret ? 2 : 0;
}
