# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0

import os
import random
import logging
from pathlib import Path

import cocotb
from cocotb.types import LogicArray
from cocotb.handle import *
from cocotb.clock import Clock
from cocotb.triggers import Timer, Edge, RisingEdge, FallingEdge, ClockCycles, First, ValueChange
from cocotb_tools.runner import get_runner

sim = os.getenv("SIM", "icarus")
pdk_root = os.getenv("PDK_ROOT", Path("~/.ciel").expanduser())
pdk = os.getenv("PDK", "gf180mcuD")
scl = os.getenv("SCL", "gf180mcu_fd_sc_mcu7t5v0")
gl = os.getenv("GL", False)
slot = os.getenv("SLOT", "1x1")

hdl_toplevel = "chip_top"

def get_packed_field(handle, start, stop=None):
    full_value = handle.value
    if stop is None:
        return full_value[start]
    else:
        return full_value[start:stop]
    
def set_packed_field(handle, start, stop=None, *, value):
    full_value = LogicArray('z' * 40, 40)
    if stop is None:
        full_value[start] = value
    else:
        full_value[start:stop] = value
    handle.value = full_value

async def value_change_packed_field(handle, start, stop=None):
    value_changed = False
    while not value_changed:
        old_value = get_packed_field(handle, start, stop)
        await ValueChange(handle)
        new_value = get_packed_field(handle, start, stop)
        value_changed = new_value != old_value


async def set_defaults(dut):
    set_packed_field(dut.bidir_PAD, 4, value = 0b1)

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
    await start_clock(dut.clk_PAD)
    await reset(dut.rst_n_PAD)


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
    await ClockCycles(dut.clk_PAD, 2)

    instr0 = [
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

    instr0 += [0x00] * (512 - len(instr0))

    instr1 = [
        0x37, 0x05, 0x00, 0x40,
        0x13, 0x05, 0x05, 0x00,
        0x13, 0x03, 0xF0, 0x00,
        0x93, 0x02, 0x00, 0x00,
        0x23, 0x00, 0x55, 0x00,
        0x93, 0xC2, 0x12, 0x00,
        0xB3, 0x73, 0x00, 0x00,
        0x93, 0x83, 0x13, 0x00,
        0xE3, 0x1E, 0x73, 0xFE,
        0x6F, 0xF0, 0xDF, 0xFE,
        0x00, 0x00, 0x00, 0x00,
    ]

    instr1 += [0x00] * (512 - len(instr1))

    rom = [
        0x00, 0x00, 0x00, 0x00,
        0xca, 0xfe, # preamble
        0x10, 0x00, # LOAD
        *instr0,

        0x10, 0x00, # LOAD
        *instr1,

        0x11, 0x00,
    ]

    
    # Simulate SPI FLASH READ
    set_packed_field(dut.bidir_PAD, 4, value = 0b1)
    for b in rom:
        for _ in range(8):
            set_packed_field(dut.bidir_PAD, 4, value = bool(b & 0x80))

            b <<= 1

            await value_change_packed_field(dut.bidir_PAD, 2)
            await value_change_packed_field(dut.bidir_PAD, 2)


    # Wait for a number of clock cycles
    await ClockCycles(dut.clk_PAD, 8000)

    logger.info("Done!")


def chip_top_runner():

    proj_path = Path(__file__).resolve().parent

    sources = []
    defines = {f"SLOT_{slot.upper()}": True}
    includes = [proj_path / "../src/"]

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
        sources.append(proj_path / "../src/wb_xbar.sv")
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
        sources.append(proj_path / "../ip/serv/rtl/serv_aligner.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_compdec.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_decode.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_immdec.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_bufreg.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_bufreg2.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_ctrl.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_alu.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_rf_if.v")
        sources.append(proj_path / "../ip/serv/rtl/serv_mem_if.v")
        sources.append(proj_path / "../src/racquet.sv")
        sources.append(proj_path / "../src/spi.sv")


    sources += [
        # IO pad models
        Path(pdk_root) / pdk / "libs.ref/gf180mcu_fd_io/verilog/gf180mcu_fd_io.v",
        Path(pdk_root) / pdk / "libs.ref/gf180mcu_fd_io/verilog/gf180mcu_ws_io.v",
        
        # SRAM macros
        Path(pdk_root) / pdk / "libs.ref/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v",
        
        # Custom IP
        proj_path / "../ip/gf180mcu_ws_ip__id/vh/gf180mcu_ws_ip__id.v",
        proj_path / "../ip/gf180mcu_ws_ip__logo/vh/gf180mcu_ws_ip__logo.v",

        # Logo
        proj_path / "../ip/gf180mcu_gsd__logo/vh/gf180mcu_gsd__logo.v",
    ]

    build_args = []

    if sim == "icarus":
        # For debugging
        build_args = ["-Winfloop", "-Wall", "-g2012"]
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
