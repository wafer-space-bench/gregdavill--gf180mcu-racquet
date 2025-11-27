# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0

import os
import random
import logging
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, Edge, RisingEdge, FallingEdge, ClockCycles
from cocotb_tools.runner import get_runner

sim = os.getenv("SIM", "icarus")
pdk_root = os.getenv("PDK_ROOT", Path("~/.ciel").expanduser())
pdk = os.getenv("PDK", "gf180mcuD")
scl = os.getenv("SCL", "gf180mcu_fd_sc_mcu7t5v0")
gl = os.getenv("GL", False)

hdl_toplevel = "proc_wrapper"

async def set_defaults(dut):
    dut.i_loader_en.value = 1

async def enable_power(dut):
    dut.VDD.value = 1
    dut.VSS.value = 0

async def start_clock(clock, freq=50):
    """Start the clock @ freq MHz"""
    c = Clock(clock, 1 / freq * 1000, "ns")
    cocotb.start_soon(c.start())


async def reset(reset, active_low=True, time_ns=1000):
    """Reset dut"""
    cocotb.log.info("Reset asserted...")

    reset.value = not active_low
    await Timer(time_ns, "ns")
    reset.value = active_low

    cocotb.log.info("Reset deasserted.")


async def start_up(dut):
    """Startup sequence"""
    await set_defaults(dut)
    if gl:
        await enable_power(dut)
    await start_clock(dut.i_clk)
    await reset(dut.i_rst)


@cocotb.test()
async def test_counter(dut):
    """Run the counter test"""

    # Create a logger for this testbench
    logger = logging.getLogger("my_testbench")

    logger.info("Startup sequence...")

    # Start up
    await start_up(dut)

    logger.info("Running the test...")

    # Wait for some time...
    await ClockCycles(dut.i_clk, 2)

    instr = [
        0x37, 0x05, 0x00, 0x40,
        0x13, 0x05, 0x05, 0x00,
        0x13, 0x03, 0x80, 0x00,
        0x93, 0x02, 0x00, 0x00,
        0x23, 0x00, 0x55, 0x00,
        0x93, 0xC2, 0x12, 0x00,
        0xB3, 0x73, 0x00, 0x00,
        0x93, 0x83, 0x13, 0x00,
        0xE3, 0x1E, 0x73, 0xFE,
        0x6F, 0xF0, 0xDF, 0xFE,
        0x00, 0x00, 0x00, 0x00,
    ]

    instr += [0x00] * (512 - len(instr))


    rom = [
        0x00, 0x00, 0x00, 0x00,
        0xca, 0xfe, # preamble
        0x10, 0x00, # LOAD
        
        *instr,

        0x11, 0x00,
    ]

    # Simulate SPI FLASH READ
    dut.spi_cipo.value = 0
    for v in rom:
        for _ in range(8):
            dut.spi_cipo.value = bool(v & 0x80)
            v <<= 1
            await dut.spi_sck.value_change
            await dut.spi_sck.value_change

    await ClockCycles(dut.i_clk, 5)
    dut.i_loader_en.value = 0

    

    # Wait for a number of clock cycles
    await ClockCycles(dut.i_clk, 4200)

    # Check the end result of the counter
    # assert dut.bidir_PAD.value == 100 - 1

    logger.info("Done!")


def chip_top_runner():

    proj_path = Path(__file__).resolve().parent

    sources = []
    defines = {}
    includes = []

    if gl:
        # SCL models
        sources.append(Path(pdk_root) / pdk / "libs.ref" / scl / "verilog" / f"{scl}.v")
        sources.append(Path(pdk_root) / pdk / "libs.ref" / scl / "verilog" / "primitives.v")

        # We use the powered netlist
        sources.append(proj_path / f"../final/pnl/{hdl_toplevel}.pnl.v")

        defines = {"FUNCTIONAL": True, "USE_POWER_PINS": True}
    else:
        sources.append(proj_path / "../src/chip_top.sv")
        sources.append(proj_path / "../src/chip_core.sv")
        sources.append(proj_path / "../src/proc_wrapper.sv")
        sources.append(proj_path / "../src/subservient.v")
        sources.append(proj_path / "../src/wb_spi_flash.sv")
        sources.append(proj_path / "../src/spi_flash_stream.sv")
        sources.append(proj_path / "../ip/subservient/rtl/subservient_gpio.v")
        sources.append(proj_path / "../ip/subservient/rtl/subservient_core.v")
        sources.append(proj_path / "../ip/subservient/rtl/subservient_rf_ram_if.v")
        sources.append(proj_path / "../ip/serv/servile/servile.v")
        sources.append(proj_path / "../ip/serv/servile/servile_mux.v")
        sources.append(proj_path / "../ip/serv/servile/servile_arbiter.v")
        sources.append(proj_path / "../ip/serv/servile/servile_rf_mem_if.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_rf_ram_if.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_top.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_state.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_decode.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_immdec.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_bufreg.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_bufreg2.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_ctrl.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_alu.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_rf_if.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_mem_if.v")
        sources.append(proj_path / "../ip/racquet/racquet.v")


    sources += [
        # IO pad models
        Path(pdk_root) / pdk / "libs.ref/gf180mcu_fd_io/verilog/gf180mcu_fd_io.v",
        Path(pdk_root) / pdk / "libs.ref/gf180mcu_fd_io/verilog/gf180mcu_ws_io.v",
        
        # SRAM macros
        Path(pdk_root) / pdk / "libs.ref/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v",
        
        # Custom IP
        proj_path / "../ip/gf180mcu_ws_ip__id/vh/gf180mcu_ws_ip__id.v",
        proj_path / "../ip/gf180mcu_ws_ip__logo/vh/gf180mcu_ws_ip__logo.v",
    ]

    build_args = []

    if sim == "icarus":
        # For debugging
        build_args = ["-Wall", "-g2012"]
        pass

    if sim == "verilator":
        build_args = ["--timing", "--trace", "--trace-fst", "--trace-structs"]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel=hdl_toplevel,
        defines=defines,
        always=True,
        includes=includes,
        build_args=build_args,
        waves=True,
    )

    plusargs = []

    runner.test(
        hdl_toplevel=hdl_toplevel,
        test_module="chip_top_tb,",
        plusargs=plusargs,
        waves=True,
    )


if __name__ == "__main__":
    chip_top_runner()
