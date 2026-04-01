module RF_main(
    input wire sys_clk,           // 27 MHz System Clock (H11)
    input sys_rst_n, 

    // --- ADC Interface (Bank 0) ---
    input wire [11:0] adc_data,   // ADC Parallel Data
    input wire adc_otr,           // ADC Over-Range
    output wire adc_clk_out,      // Clock to ADC

    // --- ADF4351 SPI & Control (Bank 1) ---
    output wire adf_clk,          // SPI Clock (P6)
    output wire adf_data,         // SPI MOSI (T6)
    output wire adf_le,           // Load Enable (R8)
    output wire adf_ce,           // Chip Enable (T7)
    input wire adf_mux,           // Mux Out / Ready (T8)
    input wire adf_ld,            // Lock Detect (P8)

    // --- System Control (Bank 1) ---
    output wire ref_10m_out,        // 10 MHz Reference (P9)
    output wire relay_filter,       // 1 = 5MHz bandwidth, 0 = 1MHz bandwidth
    output reg relay_gain = 1'b0,   // 1 = x33 voltage gain, 0 = x100 voltage gain

    // --- LO Output ---
    output wire LO_OUT,            // 414 MHz Output (T11)
    
    // --- UART ---
    output TX,
    
    //--- Audio Controller ---
    output wire BCK,
    output wire DOUT,
    output wire WS, 
    output wire PA_EN,

    //--- Control Inputs ---
    input S1,   // T3 Change demodulation mode
    input S2,   // T2 Increase center freq.
    input S3,   // D7 Decrease center freq.
    input S4    // C7 Change analog bandwidth 
);

// Default Control States
assign adf_clk = 1'b0;
assign adf_data = 1'b0;
assign adf_le = 1'b0;
assign adf_ce = 1'b0;
assign ref_10m_out = 1'b0; 

// --- 1. LO PLL Instantiation ---
wire lo_lock;
Gowin_rPLL LO_414MHZ(
    .clkout(LO_OUT),   
    .clkin(sys_clk),
    .lock(lo_lock)    
);

// --- 2. Sampling PLL Instantiation ---
wire sampling_lock;
wire clk_20mhz;
Gowin_rPLL_sampling SAMPLING_20MHZ(
    .clkout(clk_20mhz),
    .clkin(sys_clk),          
    .lock(sampling_lock)   
);
assign adc_clk_out = clk_20mhz;

// ==============================================================================
// 1. UART CONTROLLER (Moved to 20.25 MHz Domain)
// ==============================================================================

wire uart_write_done;
reg [7:0] uart_data = 8'b0;
reg uart_wr_en = 1'b0;

UART_Controller #(
    .BAUD_RATE(921_600),
    .CLOCK_FREQ(20_250_000) 
) debug_uart (
    .sys_clk(clk_20mhz),    
    .sys_rst_n(sys_rst_n),
    .write_enable(uart_wr_en), 
    .data_to_send(uart_data),  
    .RX(1'b1), 
    .TX(TX),
    .write_done(uart_write_done),
    .read_done(),
    .data_readed()
);

// ==============================================================================
// 2. AUDIO CONTROLLER
// ==============================================================================


Audio_Controller audio_c(
    .sys_clk(sys_clk),      
    .sys_rst_n(sys_rst_n),
    .audio_in(safe_audio_out), // Connect the demodulated audio here
    .BCK(BCK),
    .DOUT(DOUT),
    .WS(WS),
    .PA_EN(PA_EN)
);
  
// ==============================================================================
// 3. Debouncing & Buttons State Machine (Parallel Hz & FCW Tuning)
// ==============================================================================

reg [19:0] debounce_counter = 0;
reg S1_stable = 1, S2_stable = 1, S3_stable = 1, S4_stable = 1;
reg S1_prev = 1, S2_prev = 1, S3_prev = 1, S4_prev = 1;

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        debounce_counter <= 0;
        S1_stable <= 1; S2_stable <= 1; S3_stable <= 1; S4_stable <= 1;
    end else begin
        if (S1 == S1_stable && S2 == S2_stable && S3 == S3_stable && S4 == S4_stable) begin
            debounce_counter <= 0;
        end else begin
            debounce_counter <= debounce_counter + 1;
            if (debounce_counter >= 20'd1_000_000) begin 
                S1_stable <= S1; S2_stable <= S2; S3_stable <= S3; S4_stable <= S4;
                debounce_counter <= 0;
            end
        end
    end
end

wire S1_pressed = (!S1_stable && S1_prev); 
wire S2_pressed = (!S2_stable && S2_prev); 
wire S3_pressed = (!S3_stable && S3_prev); 
wire S4_pressed = (!S4_stable && S4_prev); 

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        S1_prev <= 1; S2_prev <= 1; S3_prev <= 1; S4_prev <= 1;
    end else begin
        S1_prev <= S1_stable; S2_prev <= S2_stable; S3_prev <= S3_stable; S4_prev <= S4_stable;
    end
end

// --- Dual Acceleration Logic ---
reg [25:0] hold_duration = 0; 
reg [20:0] repeat_timer = 0;  
reg auto_step_pulse = 0;

reg [31:0] current_step_hz = 32'd10_000;
reg [31:0] current_step_fcw = 32'd2_120_963;

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        hold_duration <= 0;
        repeat_timer <= 0;
        auto_step_pulse <= 0;
        current_step_hz <= 32'd10_000;
        current_step_fcw <= 32'd2_120_963;
    end else if (!S2_stable || !S3_stable) begin
        if (hold_duration < 26'd40_000_000) hold_duration <= hold_duration + 1;

        if (hold_duration > 26'd30_000_000) begin
            current_step_hz <= 32'd100_000;       
            current_step_fcw <= 32'd21_209_631;   
        end else if (hold_duration > 26'd15_000_000) begin
            current_step_hz <= 32'd50_000;        
            current_step_fcw <= 32'd10_604_815;   
        end else begin
            current_step_hz <= 32'd10_000;        
            current_step_fcw <= 32'd2_120_963;    
        end

        if (hold_duration > 26'd10_000_000) begin
            if (repeat_timer >= 21'd2_000_000) begin 
                repeat_timer <= 0;
                auto_step_pulse <= 1; 
            end else begin
                repeat_timer <= repeat_timer + 1;
                auto_step_pulse <= 0;
            end
        end else begin
            repeat_timer <= 0;
            auto_step_pulse <= 0;
        end
    end else begin
        hold_duration <= 0;
        repeat_timer <= 0;
        auto_step_pulse <= 0;
        current_step_hz <= 32'd10_000;
        current_step_fcw <= 32'd2_120_963;
    end
end

wire S2_action = S2_pressed || (!S2_stable && auto_step_pulse);
wire S3_action = S3_pressed || (!S3_stable && auto_step_pulse);

// --- System State Registers ---
reg mod_type = 1'b0;                     
reg [31:0] center_freq = 32'd1_000_000;     // GUI Display Frequency
reg [31:0] tuning_word = 32'd212_097_150;   // Hardware NCO FCW
reg analog_bandwidth_extended = 1'b0;    

assign relay_filter = analog_bandwidth_extended;

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        mod_type <= 1'b0;
        center_freq <= 32'd1_000_000;
        tuning_word <= 32'd212_097_150;
        analog_bandwidth_extended <= 0;
    end else begin
        if (S1_pressed) mod_type <= ~mod_type;
        
        if (S2_action) begin
            if ((center_freq <= (32'd1_000_000 - current_step_hz) && !analog_bandwidth_extended) || 
                (center_freq <= (32'd5_000_000 - current_step_hz) && analog_bandwidth_extended)) begin
                center_freq <= center_freq + current_step_hz;
                tuning_word <= tuning_word + current_step_fcw;
            end
        end

        if (S3_action) begin
            if (center_freq >= current_step_hz) begin
                center_freq <= center_freq - current_step_hz;
                tuning_word <= tuning_word - current_step_fcw;
            end
        end
        
        if (S4_pressed) analog_bandwidth_extended <= ~analog_bandwidth_extended;
    end
end

// ==============================================================================
// 4. SAMPLING
// ==============================================================================

reg [11:0] adc_data_internal = 0;

always @(negedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        adc_data_internal <= 12'b0;
        relay_gain <= 1'b1; 
    end else if (sampling_lock && lo_lock) begin
        adc_data_internal <= adc_data; 
        relay_gain <= 1'b1;
    end else begin
        adc_data_internal <= 12'b0;
    end
end

// ==============================================================================
// 5. PING-PONG BUFFER & FFT FEEDER
// ==============================================================================

wire signed [15:0] adc_signed = $signed({4'b0, adc_data_internal}) - 16'sd2048;

reg ping_pong_bank = 1'b0; 
reg [9:0] adc_write_idx = 10'b0; 
reg fft_start_pulse = 1'b0;

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        adc_write_idx <= 10'b0;
        ping_pong_bank <= 1'b0;
        fft_start_pulse <= 1'b0;
    end else begin
        fft_start_pulse <= 1'b0; 
        if (adc_write_idx == 10'd1023) begin
            adc_write_idx <= 10'b0;
            ping_pong_bank <= ~ping_pong_bank; 
            fft_start_pulse <= 1'b1;           
        end else begin
            adc_write_idx <= adc_write_idx + 1;
        end
    end
end

wire [10:0] ram_write_addr = {ping_pong_bank, adc_write_idx};
wire [9:0] fft_requested_idx; 
wire [10:0] ram_read_addr = {~ping_pong_bank, fft_requested_idx};
wire [15:0] ram_read_data;    

Gowin_SDPB_fft fft_bsram(
    .dout(ram_read_data),   
    .clka(clk_20mhz),       
    .cea(1'b1),             
    .reseta(~sys_rst_n),    
    .clkb(clk_20mhz),    
    .ceb(1'b1),             
    .resetb(~sys_rst_n),    
    .oce(1'b1),             
    .ada(ram_write_addr),   
    .din(adc_signed),       
    .adb(ram_read_addr)     
);

wire [15:0] fft_out_re;
wire [15:0] fft_out_im;
wire fft_sod, fft_ipd, fft_eod, fft_busy;
wire fft_soud, fft_opd, fft_eoud;

FFT_Top custom_fft_core (
    .clk(clk_20mhz),            
    .rst(~sys_rst_n),           
    .start(fft_start_pulse),    
    .xn_re(ram_read_data),      
    .xn_im(16'b0),              
    .idx(fft_requested_idx),    
    .sod(fft_sod),              
    .ipd(fft_ipd),              
    .eod(fft_eod),              
    .busy(fft_busy),            
    .soud(fft_soud),            
    .opd(fft_opd),              
    .eoud(fft_eoud),            
    .xk_re(fft_out_re),         
    .xk_im(fft_out_im)          
);

// ==============================================================================
// 6. FFT MAGNITUDE APPROXIMATION
// ==============================================================================

wire [15:0] abs_re = fft_out_re[15] ? (~fft_out_re + 1'b1) : fft_out_re;
wire [15:0] abs_im = fft_out_im[15] ? (~fft_out_im + 1'b1) : fft_out_im;
wire [15:0] max_val = (abs_re > abs_im) ? abs_re : abs_im;
wire [15:0] min_val = (abs_re > abs_im) ? abs_im : abs_re;

wire [15:0] mag_16bit = max_val + (min_val >> 2) + (min_val >> 3);

// ==============================================================================
// 7. VRAM BUFFER & SYNCHRONOUS FRAME LOCK
// ==============================================================================

reg frame_req = 1'b0;       
reg frame_ready = 1'b0;     
reg vram_we = 1'b0;
reg [9:0] vram_write_addr = 10'b0;

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        vram_write_addr <= 10'b0;
        vram_we <= 1'b0;
        frame_ready <= 1'b0;
    end else begin
        if (frame_req && !frame_ready) begin
            if (fft_soud) begin
                vram_we <= 1'b1;         
                vram_write_addr <= 10'b0;
            end
        end
        
        if (vram_we && fft_opd) begin
            vram_write_addr <= vram_write_addr + 1;
        end
        
        if (fft_eoud && vram_we) begin
            vram_we <= 1'b0;
            frame_ready <= 1'b1;         
        end
        
        if (!frame_req) begin
            frame_ready <= 1'b0;
        end
    end
end

wire [9:0] vram_read_addr;
wire [15:0] vram_read_data;

Gowin_SDPB_vram custom_vram (
    .clka(clk_20mhz),           
    .cea(vram_we && fft_opd),   
    .reseta(~sys_rst_n),        
    .ada(vram_write_addr),      
    .din(mag_16bit),            

    .clkb(clk_20mhz),           
    .ceb(1'b1),                 
    .resetb(~sys_rst_n),        
    .oce(1'b1),                 
    .adb(vram_read_addr),       
    .dout(vram_read_data)       
);

// ==============================================================================
// 8. UART PACKETIZER STATE MACHINE (16-Bit Payload)
// ==============================================================================

localparam ST_DELAY        = 5'd0;
localparam ST_WAIT_FRAME   = 5'd1; 
localparam ST_SYNC1        = 5'd2;
localparam ST_SYNC2        = 5'd3;
localparam ST_FLAGS        = 5'd4;
localparam ST_FREQ3        = 5'd5;
localparam ST_FREQ2        = 5'd6;
localparam ST_FREQ1        = 5'd7;
localparam ST_FREQ0        = 5'd8;
localparam ST_BIN_FETCH    = 5'd9;
localparam ST_BIN_WAIT     = 5'd10;
localparam ST_BIN_SEND_MSB = 5'd11;
localparam ST_BIN_SEND_LSB = 5'd12;
localparam ST_TX_CLEAR     = 5'd13;

reg [4:0] tx_state = ST_DELAY;
reg [4:0] next_tx_state = ST_DELAY;
reg [19:0] delay_cnt = 20'd0;
reg [10:0] bin_cnt = 11'd0; 

reg [9:0] vram_rd_addr_reg = 10'd0;
assign vram_read_addr = vram_rd_addr_reg;

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        tx_state <= ST_DELAY;
        next_tx_state <= ST_DELAY;
        delay_cnt <= 20'd0;
        bin_cnt <= 11'd0;
        uart_wr_en <= 1'b0;
        uart_data <= 8'h00;
        vram_rd_addr_reg <= 10'd0;
        frame_req <= 1'b0;
    end else begin
        case (tx_state)
            ST_DELAY: begin
                uart_wr_en <= 1'b0;
                frame_req <= 1'b0; 
                if (delay_cnt >= 20'd200_000) begin
                    delay_cnt <= 20'd0;
                    tx_state <= ST_WAIT_FRAME;
                end else begin
                    delay_cnt <= delay_cnt + 1;
                end
            end

            ST_WAIT_FRAME: begin
                frame_req <= 1'b1; 
                if (frame_ready) tx_state <= ST_SYNC1;
            end

            ST_SYNC1: begin
                uart_data <= 8'hAA; 
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    next_tx_state <= ST_SYNC2; 
                    tx_state <= ST_TX_CLEAR;   
                end
            end

            ST_SYNC2: begin
                uart_data <= 8'h55; 
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    next_tx_state <= ST_FLAGS;
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_FLAGS: begin
                uart_data <= {6'b000000, analog_bandwidth_extended, mod_type};
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    next_tx_state <= ST_FREQ3;
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_FREQ3: begin
                uart_data <= center_freq[31:24]; 
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    next_tx_state <= ST_FREQ2;
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_FREQ2: begin
                uart_data <= center_freq[23:16];
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    next_tx_state <= ST_FREQ1;
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_FREQ1: begin
                uart_data <= center_freq[15:8];
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    next_tx_state <= ST_FREQ0;
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_FREQ0: begin
                uart_data <= center_freq[7:0]; 
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    bin_cnt <= 11'd0; 
                    next_tx_state <= ST_BIN_FETCH;
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_BIN_FETCH: begin
                vram_rd_addr_reg <= bin_cnt[9:0];
                tx_state <= ST_BIN_WAIT;
            end

            ST_BIN_WAIT: begin
                tx_state <= ST_BIN_SEND_MSB;
            end

            ST_BIN_SEND_MSB: begin
                uart_data <= vram_read_data[15:8]; 
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    next_tx_state <= ST_BIN_SEND_LSB;
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_BIN_SEND_LSB: begin
                uart_data <= vram_read_data[7:0];  
                uart_wr_en <= 1'b1;
                if (uart_write_done) begin
                    uart_wr_en <= 1'b0;
                    if (bin_cnt == 11'd1023) begin
                        next_tx_state <= ST_DELAY;
                    end else begin
                        bin_cnt <= bin_cnt + 1;
                        next_tx_state <= ST_BIN_FETCH;
                    end
                    tx_state <= ST_TX_CLEAR;
                end
            end

            ST_TX_CLEAR: begin
                uart_wr_en <= 1'b0; 
                if (!uart_write_done) tx_state <= next_tx_state; 
            end

            default: tx_state <= ST_DELAY;
        endcase
    end
end

// ==============================================================================
// 9. DIGITAL DOWNCONVERTER (NCO, QUADRANT MAPPING, & MIXER)
// ==============================================================================

reg [31:0] phase_acc = 0;

// The Phase Accumulator Engine
always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        phase_acc <= 32'b0;
    end else begin
        phase_acc <= phase_acc + tuning_word; 
    end
end

// Quadrant Extraction
wire [1:0] quad = phase_acc[31:30];
wire [15:0] sub_angle = phase_acc[29:14];

// Triangle Fold
wire [15:0] folded_angle = (quad[0] == 1'b1) ? ~sub_angle : sub_angle;

// Binary to Radian Conversion
wire [31:0] radian_mult = folded_angle * 17'd51472;
wire [16:0] cordic_theta = radian_mult[31:16]; 

wire signed [16:0] cordic_cos_out;
wire signed [16:0] cordic_sin_out;

CORDIC_Top nco_inst (
    .clk(clk_20mhz),
    .rst(~sys_rst_n),
    .x_i(17'd19898),        
    .y_i(17'd0),
    .theta_i(cordic_theta), 
    .x_o(cordic_cos_out),   
    .y_o(cordic_sin_out),   
    .theta_o()
);

// Apply Quadrant Signs
reg signed [15:0] nco_i = 0; 
reg signed [15:0] nco_q = 0; 

always @(posedge clk_20mhz) begin
    case (quad)
        2'b00: begin nco_i <=  cordic_cos_out[15:0]; nco_q <=  cordic_sin_out[15:0]; end 
        2'b01: begin nco_i <= -cordic_cos_out[15:0]; nco_q <=  cordic_sin_out[15:0]; end 
        2'b10: begin nco_i <= -cordic_cos_out[15:0]; nco_q <= -cordic_sin_out[15:0]; end 
        2'b11: begin nco_i <=  cordic_cos_out[15:0]; nco_q <= -cordic_sin_out[15:0]; end 
    endcase
end

// The Mixer (Inferring the 18x18 Hardware DSP Multipliers)
reg signed [31:0] mixer_i = 0;
reg signed [31:0] mixer_q = 0;

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        mixer_i <= 32'b0;
        mixer_q <= 32'b0;
    end else if (sampling_lock && lo_lock) begin
        mixer_i <= adc_signed * nco_i;
        mixer_q <= adc_signed * nco_q;
    end
end

// ==============================================================================
// 10. CIC FILTER (Low-Pass Filter & Decimation to ~50.6 kHz)
// ==============================================================================

parameter DECIMATION_RATE = 400;

// --- 64-Bit Registers to handle CIC bit growth ---
// I-Channel Integrators
reg signed [63:0] int1_i = 0, int2_i = 0, int3_i = 0;
// Q-Channel Integrators
reg signed [63:0] int1_q = 0, int2_q = 0, int3_q = 0;

// I-Channel Combs & Delays
reg signed [63:0] comb1_i = 0, comb2_i = 0, comb3_i = 0;
reg signed [63:0] dly1_i = 0,  dly2_i = 0,  dly3_i = 0;
// Q-Channel Combs & Delays
reg signed [63:0] comb1_q = 0, comb2_q = 0, comb3_q = 0;
reg signed [63:0] dly1_q = 0,  dly2_q = 0,  dly3_q = 0;

// Decimation Counter
reg [8:0] dec_cnt = 0;

// Final Filtered Baseband Outputs
reg signed [31:0] baseband_i = 0;
reg signed [31:0] baseband_q = 0;
reg baseband_valid = 1'b0; // Pulses HIGH when a new 50kHz sample is ready

always @(posedge clk_20mhz or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        int1_i <= 0; int2_i <= 0; int3_i <= 0;
        int1_q <= 0; int2_q <= 0; int3_q <= 0;
        
        comb1_i <= 0; comb2_i <= 0; comb3_i <= 0;
        dly1_i <= 0;  dly2_i <= 0;  dly3_i <= 0;
        
        comb1_q <= 0; comb2_q <= 0; comb3_q <= 0;
        dly1_q <= 0;  dly2_q <= 0;  dly3_q <= 0;
        
        dec_cnt <= 0;
        baseband_i <= 0;
        baseband_q <= 0;
        baseband_valid <= 1'b0;
        
    end else if (sampling_lock && lo_lock) begin
        
        // --------------------------------------------------------
        // 1. INTEGRATOR STAGES (Runs at full 20.25 MHz)
        // --------------------------------------------------------
        int1_i <= int1_i + mixer_i; // mixer_i is 32-bit, automatically sign-extended to 64
        int2_i <= int2_i + int1_i;
        int3_i <= int3_i + int2_i;
        
        int1_q <= int1_q + mixer_q;
        int2_q <= int2_q + int1_q;
        int3_q <= int3_q + int2_q;
        
        // --------------------------------------------------------
        // 2. DECIMATION (Divides clock down to ~50.6 kHz)
        // --------------------------------------------------------
        baseband_valid <= 1'b0; // Default to low
        
        if (dec_cnt == DECIMATION_RATE - 1) begin
            dec_cnt <= 0;
            
            // --------------------------------------------------------
            // 3. COMB STAGES (Runs only when decimation counter resets)
            // --------------------------------------------------------
            // I-Channel Subtractions
            comb1_i <= int3_i  - dly1_i;
            comb2_i <= comb1_i - dly2_i;
            comb3_i <= comb2_i - dly3_i;
            
            dly1_i <= int3_i;
            dly2_i <= comb1_i;
            dly3_i <= comb2_i;
            
            // Q-Channel Subtractions
            comb1_q <= int3_q  - dly1_q;
            comb2_q <= comb1_q - dly2_q;
            comb3_q <= comb2_q - dly3_q;
            
            dly1_q <= int3_q;
            dly2_q <= comb1_q;
            dly3_q <= comb2_q;
            
            // --------------------------------------------------------
            // 4. BIT TRUNCATION (Scaling back down for Demodulation)
            // --------------------------------------------------------
            // The 64-bit numbers are heavily shifted up. We take the topmost 
            // useful 32 bits and pass them to our AM/FM demodulator.
            // (You may need to tweak the [50:19] slice later depending on actual signal volume)
            baseband_i <= comb3_i[50:19]; 
            baseband_q <= comb3_q[50:19];
            
            baseband_valid <= 1'b1; // Tell the demodulator a new audio sample is ready!
            
        end else begin
            dec_cnt <= dec_cnt + 1;
        end
    end
end

// ==============================================================================
// 11. DUAL DEMODULATOR (AM & FM)
// ==============================================================================

// --- A. AM DEMODULATOR (Alpha-Max, Beta-Min) ---
wire [31:0] abs_i = baseband_i[31] ? (~baseband_i + 1'b1) : baseband_i;
wire [31:0] abs_q = baseband_q[31] ? (~baseband_q + 1'b1) : baseband_q;

wire [31:0] max_val_am = (abs_i > abs_q) ? abs_i : abs_q;
wire [31:0] min_val_am = (abs_i > abs_q) ? abs_q : abs_i;

wire signed [31:0] am_mag_raw = max_val_am + (min_val_am >> 2) + (min_val_am >> 3);

// --- B. FM DEMODULATOR (Polar Discriminator) ---
// Formula: FM = (I_prev * Q_curr) - (Q_prev * I_curr)

reg signed [15:0] i_prev = 0;
reg signed [15:0] q_prev = 0;

// Slice the top 16 bits so they fit cleanly into the 18x18 hardware multipliers
wire signed [15:0] current_i_16 = baseband_i[31:16];
wire signed [15:0] current_q_16 = baseband_q[31:16];

// The Cross-Multiplication (Gowin automatically infers 2 DSP multipliers here)
wire signed [31:0] fm_mult1 = i_prev * current_q_16;
wire signed [31:0] fm_mult2 = q_prev * current_i_16;
wire signed [31:0] fm_raw = fm_mult1 - fm_mult2;

always @(posedge clk_20mhz) begin
    if (baseband_valid) begin
        // Store current samples to become the "previous" samples for the next clock
        i_prev <= current_i_16;
        q_prev <= current_q_16;
    end
end

// --- INDEPENDENT FM VOLUME BOOST ---
// Because delta-theta is a tiny number, multiply the FM signal so it 
// matches the natural volume scale of the AM signal.
wire signed [31:0] fm_boosted = fm_raw <<< 4;

// --- C. DEMODULATOR SELECTOR ---
// Button S1 toggles `mod_type`. 0 = AM, 1 = FM.
wire signed [31:0] active_demod_raw = (mod_type == 1'b1) ? fm_boosted : am_mag_raw;

// ==============================================================================
// 12. AUTOMATIC GAIN CONTROL (AGC), DC BLOCKER & SATURATOR
// ==============================================================================

reg signed [31:0] dc_avg = 0;

// The DC Blocker acts as a carrier remover for AM, and an auto-centering filter for FM!
wire signed [31:0] raw_ac_audio = active_demod_raw - dc_avg;

// --- AGC Variables ---
reg [15:0] agc_gain = 16'd1024;   
reg [15:0] agc_timer = 0;         
reg [31:0] peak_level = 0;        

// 1. MULTIPLY
wire signed [47:0] agc_multiplied = raw_ac_audio * $signed({1'b0, agc_gain});

// 2. NORMALIZE
wire signed [31:0] scaled_audio = agc_multiplied >>> 26; 

// 3. PEAK DETECTION WIRE
wire [31:0] current_abs = scaled_audio[31] ? -scaled_audio : scaled_audio;

reg signed [15:0] safe_audio_out = 0; 

always @(posedge clk_20mhz) begin
    if (baseband_valid) begin
        
        // --- A. Slow-moving DC Tracker ---
        dc_avg <= dc_avg + ((active_demod_raw - dc_avg) >>> 8);
        
        // --- B. HARDWARE SATURATOR ---
        if (scaled_audio > 32767) begin
            safe_audio_out <= 16'd32767;      
        end 
        else if (scaled_audio < -32768) begin
            safe_audio_out <= -16'd32768;     
        end 
        else begin
            safe_audio_out <= scaled_audio[15:0]; 
        end
        
        // --- C. AUTOMATIC GAIN CONTROL (With Noise Gate) ---
        if (current_abs > peak_level) begin
            peak_level <= current_abs;
        end
        
        agc_timer <= agc_timer + 1;
        if (agc_timer >= 16'd500) begin
            agc_timer <= 0;
            
            if (peak_level > 32'd18000) begin
                if (agc_gain > 16'd50) agc_gain <= agc_gain - 16'd50;
            end else if (peak_level > 32'd5000 && peak_level < 32'd15000) begin
                if (agc_gain < 16'd60000) agc_gain <= agc_gain + 16'd10;
            end else if (peak_level <= 32'd5000) begin
                if (agc_gain > 16'd1026) agc_gain <= agc_gain - 16'd2;
                else if (agc_gain < 16'd1022) agc_gain <= agc_gain + 16'd2;
            end
            
            peak_level <= 0;
        end
        
    end
end

endmodule