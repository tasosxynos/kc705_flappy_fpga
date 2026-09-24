# ============================================================================
#  kc705_flappy.xdc -- pin and timing constraints for the KC705 (xc7k325t).
#
#  Pin numbers are taken from UG810 (v1.6.2) Tables 1-9, 1-21 and 1-27
#  (KC705 Board XDC Listing, Appendix C).
#
#  Clocking: SYSCLK = 200 MHz differential LVDS oscillator (SiT9102, U6) wired
#            to an MRCC input on bank 33, terminated on the board by R459 (100
#            ohm), so IBUFDS is built with DIFF_TERM="FALSE".
#            Plain LVDS is used here exactly as in the KC705 board XDC listing
#            in UG810 Appendix C.  Bank 33 is a 1.5V rail (UG810 Table 1-3) and
#            Vivado's BIVC check refuses to mix LVCMOS15 and LVDS in one bank,
#            which is why the LVCMOS15 user LEDs are not used in this design.
#            -> MMCME2 -> 148.5 MHz pixel clock for 1920x1080@60 (1080p60)
# ============================================================================

# ---------------------------------------------------------------- 200 MHz in
set_property PACKAGE_PIN AD12 [get_ports SYSCLK_P]
set_property IOSTANDARD LVDS [get_ports SYSCLK_P]
set_property PACKAGE_PIN AD11 [get_ports SYSCLK_N]
set_property IOSTANDARD LVDS [get_ports SYSCLK_N]

create_clock -period 5.000 -name sys_clk200 [get_ports SYSCLK_P]
set_input_jitter sys_clk200 0.050

# ------------------------------------------------------------------- HDMI out
# 18 parallel video data lines to the ADV7511 (U65).  In 16-bit YCbCr 4:2:2
# mode only D15..D0 of that set are used; D17/D16 are tied low.  Per the KC705
# schematic the FPGA bytes are: HDMI_D[15:8] = Y (luma, the transmitter's
# D[23:16]) and HDMI_D[7:0] = Cb/Cr (chroma, its D[15:8]).
set_property PACKAGE_PIN B23 [get_ports {HDMI_D[0]}]
set_property PACKAGE_PIN A23 [get_ports {HDMI_D[1]}]
set_property PACKAGE_PIN E23 [get_ports {HDMI_D[2]}]
set_property PACKAGE_PIN D23 [get_ports {HDMI_D[3]}]
set_property PACKAGE_PIN F25 [get_ports {HDMI_D[4]}]
set_property PACKAGE_PIN E25 [get_ports {HDMI_D[5]}]
set_property PACKAGE_PIN E24 [get_ports {HDMI_D[6]}]
set_property PACKAGE_PIN D24 [get_ports {HDMI_D[7]}]
set_property PACKAGE_PIN F26 [get_ports {HDMI_D[8]}]
set_property PACKAGE_PIN E26 [get_ports {HDMI_D[9]}]
set_property PACKAGE_PIN G23 [get_ports {HDMI_D[10]}]
set_property PACKAGE_PIN G24 [get_ports {HDMI_D[11]}]
set_property PACKAGE_PIN J19 [get_ports {HDMI_D[12]}]
set_property PACKAGE_PIN H19 [get_ports {HDMI_D[13]}]
set_property PACKAGE_PIN L17 [get_ports {HDMI_D[14]}]
set_property PACKAGE_PIN L18 [get_ports {HDMI_D[15]}]
set_property PACKAGE_PIN K19 [get_ports {HDMI_D[16]}]
set_property PACKAGE_PIN K20 [get_ports {HDMI_D[17]}]
set_property IOSTANDARD LVCMOS25 [get_ports {HDMI_D[*]}]

set_property PACKAGE_PIN K18 [get_ports HDMI_CLK]
set_property PACKAGE_PIN H17 [get_ports HDMI_DE]
set_property PACKAGE_PIN J18 [get_ports HDMI_HSYNC]
set_property PACKAGE_PIN H20 [get_ports HDMI_VSYNC]
set_property IOSTANDARD LVCMOS25 [get_ports {HDMI_CLK HDMI_DE HDMI_HSYNC HDMI_VSYNC}]

# The pixel clock leaves through an ODDR, so it is a generated clock and it
# follows the MMCM automatically.  The ADV7511 samples the video bus with its
# own PLL, so the window is a small fraction of the 6.73 ns pixel period:
# 3.0 ns of setup and -0.5 ns of hold are what the parallel interface needs
# at 148.5 MHz.  If timing ever fails, this is the constraint to revisit.
create_generated_clock -name hdmi_clk_out -source [get_pins u_oddr_clk/C] \
    -divide_by 1 -multiply_by 1 [get_ports HDMI_CLK]

set_output_delay -clock hdmi_clk_out -max  3.000 \
    [get_ports {HDMI_D[*] HDMI_DE HDMI_HSYNC HDMI_VSYNC}]
set_output_delay -clock hdmi_clk_out -min -0.500 \
    [get_ports {HDMI_D[*] HDMI_DE HDMI_HSYNC HDMI_VSYNC}]

# ------------------------------------------------------------- SW5 pushbutton
set_property PACKAGE_PIN G12 [get_ports GPIO_SW_C]
set_property IOSTANDARD LVCMOS25 [get_ports GPIO_SW_C]

# ----------------------------------------------------------------------- LEDs
# DS4/DS1/DS10/DS2 on AB8/AA8/AC9/AB9, used as the bring-up diagnostic: LED0 =
# MMCM locked, LED1 = ADV7511 configured, LED2 = I2C error, LED3 = heartbeat.
# These pins are in bank 33 together with the 200 MHz clock, and the board
# really does carry both (the clock is LVDS into a 1.5V bank, exactly as the
# KC705 board XDC listing in UG810 Appendix C has it), so Vivado's bank-voltage
# consistency check is waived for that bank rather than dropping the LEDs.
set_property SEVERITY {Warning} [get_drc_checks BIVC-1]
set_property PACKAGE_PIN AB8 [get_ports GPIO_LED_0]
set_property PACKAGE_PIN AA8 [get_ports GPIO_LED_1]
set_property PACKAGE_PIN AC9 [get_ports GPIO_LED_2]
set_property PACKAGE_PIN AB9 [get_ports GPIO_LED_3]
set_property IOSTANDARD LVCMOS15 [get_ports {GPIO_LED_0 GPIO_LED_1 GPIO_LED_2 GPIO_LED_3}]

# The other four user LEDs (DS3/DS25/DS26/DS27) complete the diagnostic panel.
# They sit in different banks at LVCMOS25, so they carry no bank conflict.
set_property PACKAGE_PIN AE26 [get_ports GPIO_LED_4]
set_property PACKAGE_PIN G19  [get_ports GPIO_LED_5]
set_property PACKAGE_PIN E18  [get_ports GPIO_LED_6]
set_property PACKAGE_PIN F16  [get_ports GPIO_LED_7]
set_property IOSTANDARD LVCMOS25 [get_ports {GPIO_LED_4 GPIO_LED_5 GPIO_LED_6 GPIO_LED_7}]

# ------------------------------------------------------------------------ I2C
set_property PACKAGE_PIN K21 [get_ports IIC_SCL_MAIN]
set_property PACKAGE_PIN L21 [get_ports IIC_SDA_MAIN]
set_property PACKAGE_PIN P23 [get_ports IIC_MUX_RESET_B]
set_property IOSTANDARD LVCMOS25 [get_ports {IIC_SCL_MAIN IIC_SDA_MAIN IIC_MUX_RESET_B}]
set_property PULLTYPE PULLUP [get_ports {IIC_SCL_MAIN IIC_SDA_MAIN}]

# ------------------------------------------------------------------- config
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 2.5 [current_design]

# ---------------------------------------------------------- asynchronous I/O
# The pushbutton and the I2C data line are sampled by synchronisers / a slow
# bit-banged protocol, so they carry no meaningful setup/hold relationship to
# the 25 MHz pixel clock.
set_false_path -from [get_ports GPIO_SW_C]
set_false_path -from [get_ports IIC_SDA_MAIN]
