from amaranth import *
from amaranth.lib import data, stream
from amaranth.back import verilog

from amaranth.lib.cdc import ResetSynchronizer


from spi import SPI


class Opcode(data.Enum):
    LOAD = 0x10
    DONE = 0x11
    NO_OP = 0xFF

class Racquet(Elaboratable):
    """
    Racquet: Flinging serv's across the court 

    """

    def __init__(self):

        self.clk = Signal()
        self.rst = Signal(reset_less=True)

        self.spi = SPI()

        self.o_loader_payload = Signal(8)
        self.o_loader_valid = Signal(1)
        self.i_loader_ready = Signal(1)

        self.loader_enabled = Signal(1, reset=1)

    def elaborate(self, platform):
        m = Module()
        m.domains.sync = ClockDomain('sync', async_reset=True)
        m.d.comb += ResetSignal().eq(self.rst)
        m.d.comb += ClockSignal().eq(self.clk)

        m.submodules.spi = spi = self.spi

        m.d.comb += spi.divisor.eq(2)

        counter = Signal(range(0, 2048))
        opcode = Signal(16)
        opcode_reg = Signal(8, reset=0)

        with m.If(spi.resp.ready & spi.resp.valid):
            m.d.sync += opcode_reg.eq(spi.resp.p.data)


        m.d.comb += self.loader_enabled.eq(1)
        with m.FSM():
            with m.State("RESET"):
                m.next = "ADDR"


            with m.State("ADDR"):
                m.d.comb += [
                    spi.cmd.valid.eq(1),
                    spi.cmd.p.data.eq(0x03_000000),
                    spi.cmd.p.bits.eq(32),
                    spi.cmd.p.chip.eq(1),
                ]
                with m.If(spi.cmd.ready & spi.cmd.valid):
                    m.d.sync += counter.eq(128)
                    m.next = "PREAMBLE_WAIT"
            
            with m.State("PREAMBLE_WAIT"):
                m.d.comb += [
                    spi.cmd.valid.eq(counter > 0),
                    spi.cmd.p.data.eq(0),
                    spi.cmd.p.bits.eq(8),
                    spi.cmd.p.chip.eq(1),
                ]
                with m.If(spi.cmd.ready & spi.cmd.valid):
                    ...
                
                m.d.comb += spi.resp.ready.eq(1)
                with m.If(spi.resp.ready & spi.resp.valid):
                    m.d.comb += opcode.eq(Cat(spi.resp.p.data, opcode_reg))

                    m.d.sync += counter.eq(counter - 1)
                    with m.If(opcode[0:16] == 0xcafe):
                        m.next = "OPCODE_LOOP"
                    with m.If(counter == 0):
                        m.next = "DONE"


            with m.State("OPCODE_LOOP"):
                m.d.comb += [
                    spi.cmd.valid.eq(counter > 0),
                    spi.cmd.p.data.eq(0),
                    spi.cmd.p.bits.eq(8),
                    spi.cmd.p.chip.eq(1),
                ]
                with m.If(spi.cmd.ready & spi.cmd.valid):
                    ...
                
                m.d.comb += spi.resp.ready.eq(1)
                with m.If(spi.resp.ready & spi.resp.valid):
                    m.d.comb += opcode.eq(Cat(spi.resp.p.data, opcode_reg))
                    
                    with m.Switch(opcode[8:16]):
                        with m.Case(0x00, 0xFF):
                            ... # NOP
                        with m.Case(Opcode.LOAD):
                            m.next = "LOAD"
                            m.d.sync += counter.eq(511)
                        with m.Case(Opcode.DONE):
                            m.next = "DONE"
                        with m.Default():
                            ...

            with m.State("DONE"):
                m.d.comb += [
                    spi.cmd.valid.eq(1),
                    spi.cmd.p.data.eq(0),
                    spi.cmd.p.bits.eq(0),
                    spi.cmd.p.chip.eq(0),
                ]
                with m.If(spi.cmd.ready & spi.cmd.valid):
                    m.next = "FIN"
                
                m.d.comb += spi.resp.ready.eq(1)

            with m.State("FIN"):
                m.d.comb += spi.resp.ready.eq(1)
                m.d.comb += self.loader_enabled.eq(0)



            with m.State("LOAD"):
                m.d.comb += [
                    spi.cmd.valid.eq(counter > 0),
                    spi.cmd.p.data.eq(0),
                    spi.cmd.p.bits.eq(8),
                    spi.cmd.p.chip.eq(1),
                ]

                m.d.comb += [
                    self.o_loader_payload.eq(spi.resp.p.data[0:8]),
                    self.o_loader_valid.eq(spi.resp.valid),
                    spi.resp.ready.eq(self.i_loader_ready),
                ]

                # m.d.comb += spi.resp.ready.eq(1)
                with m.If(spi.resp.ready & spi.resp.valid):
                    m.d.sync += counter.eq(counter - 1)
                    with m.If(counter == 0):
                        m.next = "OPCODE_LOOP"

        return m


if __name__ == "__main__":
    racquet = Racquet()
    verilog_text = verilog.convert(
        racquet,
        name="racquet",
        ports=[racquet.clk, racquet.rst,
               racquet.spi.sck,racquet.spi.copi,racquet.spi.cipo,racquet.spi.cs,
               racquet.o_loader_payload, racquet.o_loader_valid, racquet.i_loader_ready,
               racquet.loader_enabled],
        strip_internal_attrs=True
    )

    with open("racquet.v", "w") as f:
        f.write(verilog_text)
    print("Generated verilog: racquet.v")

