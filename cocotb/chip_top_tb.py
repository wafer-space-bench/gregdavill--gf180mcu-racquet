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
import tempfile
import subprocess
import shutil

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

def gcc_compile(asm: str) -> bytes:
    tmp = tempfile.TemporaryDirectory()
    try:
        work = Path(tmp.name)
        src = work / "prog.S"
        obj = work / "prog.o"
        out = work / "prog.bin"
        link = Path(__file__).parent / "link.ld"
        src.write_text(asm)

        p = subprocess.run(["riscv64-unknown-elf-gcc", "-nostartfiles", "-march=rv32i", "-mabi=ilp32", "-T", str(link), "-o", str(obj), str(src)],
                            capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"compile failed: {p.stderr.strip()}")

        p = subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary", str(obj), str(out)],
                            capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"objcopy failed: {p.stderr.strip()}")
        b = bytearray(out.read_bytes())
        return b + bytearray(512 - len(b))
    finally:
        tmp.cleanup()

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

    asm0 = """
#define GPIO_BASE 0x40001000

.globl _start
_start: li	a0, GPIO_BASE
        li	t1, 3
        addi	t0, zero, 10

bl1:    sb	t0, 0(a0)
        xori	t0, t0, 1

    	and	t2, zero, zero
time1:	addi	t2, t2, 1
        bne	t1, t2, time1
        j	bl1
"""

    asm1 = """
#define GPIO_BASE 0x80002000

.globl _start
_start: li	a0, GPIO_BASE
        
bl1:    lb	t0, 0(a0)
        j	bl1
"""
    bin0 = gcc_compile(asm0)
    bin1 = gcc_compile(asm1)

    for idx, b in enumerate(bin0):
        dut.u_chip_core.gen_proc_wrapper[0].u_proc_wrapper.u_sram.mem[idx].value = LogicArray(b, 8)
    for idx, b in enumerate(bin1):
        dut.u_chip_core.gen_proc_wrapper[1].u_proc_wrapper.u_sram.mem[idx].value = LogicArray(b, 8)
    for idx, b in enumerate(bin1):
        dut.u_chip_core.gen_proc_wrapper[2].u_proc_wrapper.u_sram.mem[idx].value = LogicArray(b, 8)

    # Cores are held in reset unless their SRAM is loaded. Fake loading to speed up sims
    dut.u_chip_core.gen_proc_wrapper[0].u_proc_wrapper.state.value = Force(1)
    dut.u_chip_core.gen_proc_wrapper[1].u_proc_wrapper.state.value = Force(1)
    dut.u_chip_core.gen_proc_wrapper[2].u_proc_wrapper.state.value = Force(1)

    rom = [
        0x00, 0x00, 0x00, 0x00,
        0xca, 0xfe, # preamble
        # 0x10, 0x00, # LOAD
        # *bin0,
        # 0x10, 0x00, # LOAD
        # *bin0,
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
        sources.append(proj_path / "../src/wb_queue.sv")


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
