module Audio_Controller(
    input wire sys_clk,
    input wire sys_rst_n,
    input wire signed [15:0] audio_in,
    output reg BCK = 0,
    output reg DOUT = 0,
    output reg WS = 0, // Word Select (PT8211 LCK)
    output wire PA_EN  // Enable the audio amp
);

assign PA_EN = sys_rst_n;

// --- BCK Generation (3 MHz) ---
reg [3:0] clk_counter = 0;
wire falling_edge = (clk_counter == 4) ? 1'b1 : 1'b0; 

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        clk_counter <= 0;
        BCK <= 0;
    end else begin
        if (clk_counter >= 8) begin
            clk_counter <= 0; 
        end else begin
            clk_counter <= clk_counter + 1;
        end

        if (clk_counter < 4) BCK <= 1'b1;
        else BCK <= 1'b0;            
    end
end

// --- Startup Timer ---
// Keeps outputs muted for a moment to allow the physical amplifier to stabilize
reg start_up = 0;
reg [23:0] start_up_counter = 0;
parameter START_UPPER_LIMIT = 24'd2_700_000;  

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        start_up <= 0;
        start_up_counter <= 0;
    end else begin
        if (!start_up) begin
            if (start_up_counter < START_UPPER_LIMIT) 
                start_up_counter <= start_up_counter + 1;
            else 
                start_up <= 1;
        end
    end
end

// --- Audio DAC Logic ---
reg [5:0] bit_counter;   // 0 to 63 (64 bits per full stereo frame)
reg safe_to_send = 0;
reg signed [15:0] audio_sample; // Latched copy of the incoming audio

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        bit_counter <= 0;
        WS <= 0;
        DOUT <= 0;
        safe_to_send <= 0;
        audio_sample <= 0;
    end else begin
        if (falling_edge) begin
            
            // 1. Frame Management
            if (bit_counter == 63) begin
                bit_counter <= 0;
                // Capture the live AC audio sample at the start of the frame
                // This prevents the data from changing mid-shift!
                audio_sample <= audio_in; 
            end else begin
                bit_counter <= bit_counter + 1;
            end

            // 2. WS (Word Select) Logic for PT8211
            // PT8211: High = Left Channel, Low = Right Channel
            if (bit_counter < 32) WS <= 1;
            else WS <= 0;

            // 3. Safe Start
            if (start_up == 1 && bit_counter == 63) begin
                safe_to_send <= 1;
            end
            
            // 4. Output Logic (16-bit Right-Justified Format)
            if (safe_to_send) begin
                if (bit_counter < 32) begin 
                    // --- LEFT CHANNEL ---
                    // Wait 16 clocks (pad with 0), then shift out 16 bits
                    if (bit_counter < 16)
                        DOUT <= 0;
                    else
                        DOUT <= audio_sample[31 - bit_counter]; 
                end 
                else begin 
                    // --- RIGHT CHANNEL ---
                    // Wait 16 clocks (pad with 0), then shift out 16 bits
                    if (bit_counter < 48)
                        DOUT <= 0;
                    else
                        DOUT <= audio_sample[63 - bit_counter];
                end
            end else begin
                DOUT <= 0; 
            end
        end 
    end
end

endmodule