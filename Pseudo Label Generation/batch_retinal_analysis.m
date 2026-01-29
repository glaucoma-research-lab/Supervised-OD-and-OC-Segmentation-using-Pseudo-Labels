function batch_retinal_analysis()
    clc; clear; close all;

    %% 1. Directory Setup
    inputFolder = uigetdir(pwd, 'Select Folder Containing Retinal Images');
    if isequal(inputFolder,0), return; end
    
    outputFolder = fullfile(inputFolder, 'Results_Segmentation');
    if ~exist(outputFolder, 'dir'), mkdir(outputFolder); end

    % Get list of all images
    imgFiles = [dir(fullfile(inputFolder, '*.jpg')); ...
                dir(fullfile(inputFolder, '*.png')); ...
                dir(fullfile(inputFolder, '*.tif'))];

    % Initialize table to store results
    numFiles = length(imgFiles);
    resultsSummary = cell(numFiles, 5); % Filename, DiscArea, CupArea, AreaCDR, vCDR

    %% 2. Process Each Image
    for i = 1:numFiles
        try
            fileName = imgFiles(i).name;
            fprintf('Processing [%d/%d]: %s\n', i, numFiles, fileName);
            Irgb = im2double(imread(fullfile(inputFolder, fileName)));
            [imgH, imgW, ~] = size(Irgb);

            % --- STEP A: Localization ---
            BrightnessMap = mat2gray(mean(Irgb, 3));
            
            % NCC Template Setup
            tplSize = 50; rad = 20;
            [tx, ty] = meshgrid(1:tplSize, 1:tplSize);
            discTpl = ((tx-tplSize/2).^2 + (ty-tplSize/2).^2) <= rad^2;
            
            NCC_R = normxcorr2(double(discTpl), Irgb(:,:,1));
            NCC_G = normxcorr2(double(discTpl), Irgb(:,:,2));
            
            % Crop and Combine
            rowS = floor(tplSize/2)+1; colS = floor(tplSize/2)+1;
            NCC_R = mat2gray(NCC_R(rowS:rowS+imgH-1, colS:colS+imgW-1));
            NCC_G = mat2gray(NCC_G(rowS:rowS+imgH-1, colS:colS+imgW-1));
            CombinedMap = mat2gray(NCC_R + NCC_G + BrightnessMap);

            % Find Peak and Refine
            [~, maxIdx] = max(CombinedMap(:));
            [rOD, cOD] = ind2sub(size(CombinedMap), maxIdx);
            
            % --- STEP B: Active Contour Segmentation ---
            G_seg = im2uint8(mat2gray(Irgb(:,:,2)));
            win = 80;
            r1 = max(round(rOD-win), 1); r2 = min(round(rOD+win), imgH);
            c1 = max(round(cOD-win), 1); c2 = min(round(cOD+win), imgW);
            
            patch_G = G_seg(r1:r2, c1:c2);
            patch_B = im2uint8(mat2gray(BrightnessMap(r1:r2, c1:c2)));
            
            [ph, pw] = size(patch_G);
            [px, py] = meshgrid(1:pw, 1:ph);
            lc = cOD - c1 + 1; lr = rOD - r1 + 1;
            
            init_OD = sqrt((px-lc).^2 + (py-lr).^2) <= 35;
            init_OC = sqrt((px-lc).^2 + (py-lr).^2) <= 15;
            
            % Evolve Boundaries
            f_OD_patch = activecontour(patch_G, init_OD, 200, 'edge', 'SmoothFactor', 2, 'ContractionBias', -0.1);
            %f_OC_patch = activecontour(patch_B, init_OC, 100, 'edge', 'SmoothFactor', 1);
            
            patch_B_enhanced = imadjust(patch_B); % Increases contrast to define edges better
            f_OC_patch = activecontour(patch_B_enhanced, init_OC, 300, 'edge', ...
                'SmoothFactor', 0.15, 'ContractionBias', 0);
            
            % --- STEP C: Generate Full Masks & Metrics ---
            Full_OD = false(imgH, imgW); Full_OC = false(imgH, imgW);
            Full_OD(r1:r2, c1:c2) = f_OD_patch;
            Full_OC(r1:r2, c1:c2) = f_OC_patch & f_OD_patch; % Constrain Cup to Disc

            % Calculate Metrics
            a_disc = bwarea(Full_OD);
            a_cup  = bwarea(Full_OC);
            area_CDR = a_cup / a_disc;
            
            stats_OD = regionprops(Full_OD, 'BoundingBox');
            stats_OC = regionprops(Full_OC, 'BoundingBox');
            v_CDR = stats_OC(1).BoundingBox(4) / stats_OD(1).BoundingBox(4);

            % --- STEP D: Save Outputs ---
            resultsSummary(i, :) = {fileName, a_disc, a_cup, area_CDR, v_CDR};
            
            % Save binary masks
            imwrite(Full_OD, fullfile(outputFolder, ['OD_', fileName]));
            imwrite(Full_OC, fullfile(outputFolder, ['OC_', fileName]));

        catch ME
            fprintf('Error processing %s: %s\n', fileName, ME.message);
        end
    end

    %% 3. Export CSV Report
    T = cell2table(resultsSummary, 'VariableNames', ...
        {'FileName', 'DiscArea_px', 'CupArea_px', 'Area_CDR', 'Vertical_CDR'});
    writetable(T, fullfile(outputFolder, 'Clinical_Report.csv'));
    
    fprintf('\nBatch Processing Complete!\nResults saved to: %s\n', outputFolder);
    disp(T);
end