+define+BG_GSIZE=16
+define+BG_EXP_W=5
+define+BG_MAN_W=3
+define+BG_EXP_BIAS=15
+define+BG_BUCKET_COUNT=4
+define+BG_BUCKET_WIDTH=128
+define+BG_EXP_PER_BUCKET=4
+incdir+../01_RTL/
-sverilog ../01_RTL/BG_PKG.sv
-sverilog ../01_RTL/BG_INT_MAC.sv
-sverilog ../01_RTL/BG_FP_ACC.sv
-sverilog ../01_RTL/BG_BUCKET_CTRL.sv
-sverilog ../01_RTL/BG_BUCKET_BANK.sv
-sverilog ../01_RTL/BG_PE_CORE.sv
-sverilog ../01_RTL/BUCKET_GETTER_PE.sv
