from amaranth import *
import math
from amaranth.lib import wiring, stream, data
from amaranth.lib.wiring import In, Out, connect, flipped

class SPI(wiring.Component):
    def __init__(self):
        super().__init__({

            # Command input
            "cmd": In(stream.Signature(data.StructLayout({
                "chip": 1,
                "data": 32,
                "bits": 6
            }))),

            # Response output
            "resp": Out(stream.Signature(data.StructLayout({
                "data": 32
            }))),
            "divisor": In(8),

            # SPI interface
            "sck": Out(1),
            "copi": Out(1),
            "cipo": In(1),
            "cs": Out(1, init=1)
        })

    def elaborate(self, platform):
        m = Module()

        # sck clock divider (produce half-period toggles)
        # divider ticks every sys_clk / (2 * sck_freq)
        sck_div = Signal(9, reset=0)
        sck_phase = Signal(reset=0)  # 0/1 toggles each divider expiry
        sck_reg = Signal(reset=0)

        idle = Signal()

        with m.If(~idle):
            with m.If(sck_div == 0):
                m.d.sync += sck_div.eq((self.divisor << 1) - 1)
            with m.Else():
                m.d.sync += sck_div.eq(sck_div - 1)
        with m.Else():
            m.d.sync += sck_div.eq(1)


        m.d.comb += [
            sck_phase.eq(sck_div >= self.divisor),
            sck_reg.eq(sck_div >= self.divisor),
        ]

        bit_index = Signal(range(0, 32), reset=0)  # remaining bits to shift
        tx_shift = Signal(32, reset=0)
        rx_shift = Signal(32, reset=0)

        m.d.comb += [
            self.copi.eq(tx_shift[-1]),
            self.sck.eq(sck_reg)
        ]

        m.d.comb += self.resp.p.data.eq(rx_shift)
        
        with m.FSM():
            # Handle accepting a CMD at any state to avoid idle cycles
            def accept_cmd():
                with m.If(self.cmd.valid):
                    m.d.comb += self.cmd.ready.eq(1)
                    m.d.sync += [
                        tx_shift.eq(self.cmd.p.data),
                        bit_index.eq(self.cmd.p.bits - 1),
                        self.cs.eq(~self.cmd.p.chip),  # assert CS (active low)
                    ]
                    with m.If(self.cmd.p.bits):
                        m.next = "SHIFT"

            with m.State("IDLE"):
                m.d.comb += idle.eq(1)
                accept_cmd()

            with m.State("SHIFT"):
                # On each half-clock toggle we either present the next MOSI bit
                # before the rising edge (phase=0) or sample MISO after rising edge (phase=1).
                # We act only when a divider tick happens (phase change); otherwise idle.
                with m.If(sck_div == self.divisor): 
                    # present MSB of remaining window
                    m.d.sync += tx_shift.eq(Cat(C(0,1), tx_shift[0:-1]))


                with m.If(sck_div == (self.divisor << 1) - 2):
                        m.d.sync += rx_shift.eq(Cat(self.cipo, rx_shift[0:31]))
                        # decrement bit_index when a full clock cycle (both half-phases) completed:
                        # We decrement here once per full bit (we choose to decrement on phase==1)
                        with m.If(bit_index == 0):
                            m.d.sync += self.resp.valid.eq(1)
                            m.next = "RESP"
                        with m.Else():
                            m.d.sync += bit_index.eq(bit_index - 1)
            
            with m.State("RESP"):
                # Hold state if resp stalled
                m.d.comb += idle.eq(1)
                with m.If(self.resp.ready):
                    m.d.sync += self.resp.valid.eq(0)
                    m.next = "IDLE"
                    accept_cmd()

        return m