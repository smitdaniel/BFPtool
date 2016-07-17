%% TrackPipette Finds a pipette pattern in a frame
%   Uses normalized 2D cross-correlation to detect preselected pattern
%   *IN:*
%   * vidObj  : object wrapping the video file (support native + TIFF form.)
%   * pipette : pattern of the pippete tip to be tracked (2D matrix, image)
%   * inicoor : initial coordinate to start the tracking
%   * range   : the range of frames to analyse in a video
%   * review  : number of frames used for robustness analysis (retrospective
%   mean of correlation coefficients)
%   * robustness : threshold for poor correlation warnings
%   * quality : threshold for poor contrast warnings
%   * wideField  : switch for unrestricted search in the whole field
%   * buffer  : number of failed consecutive frame searches before aborting
%   * waitbar : handle to figure of tracking progress bar started externally
%   
%   *OUT:*
%   * position   : array of pipette positions for each frame
%   * scores     : array of cross-correlation coeff values for each frame
%   * badFrames  : list of frames of failed detection
%   
%   *DETAIL:*
%   Calculates normalized cross correlation (normxcorr2) of pipette and any possible 
%   submatrix of the field (or defined subfield). The final match position
%   is calculated using elliptical paraboloid fit to the scores matrix (i.e.
%   matrix of correlation coefficients) and choosing the extremal point -- 
%   this allows to obtain sub-pixel precision. The program
%   issues warnings if the detection or contrast underperform, and calls 
%   corrective methods in attempt to improve the results (at cost).
%   ====================================================================

function [ position, scores, badFrames ] = TrackPipette( vidObj, pipette, varargin )

%% ==== Input parser and default definitions ====
wbThresh = 100;         % minimal # of frames to initialize progress bar
routineWF = 5;          % frame interval to repeat routine wide-field search
dilatedRobust = 0.97;   % minimal correlation needed for dilated pat. search
maxSkip = 5;            % maximal displacement of the pattern in one frame step in pix

persistent inp;
% parse the input; in case initial coordinate and range are not provided,
% continue by taking the whole range and search the whole field.
if isempty(inp)
    inp = inputParser;
    defaultInicoor      = [-1 -1];
    defaultRange        = -1;
    defaultReview       = 5;          % number of frames used to evaluate metric
    defaultRobustness   = 0.95;       % level of correlation to result in warning
    defaultImageQuality = 0.96;       % level of relative contrast (to maximum) to issue warning
    defaultWideField    = false;      % perform serach in the full field    
    defaultBuffer       = 5;          % grace period if search for pattern fails
    defaultWaitbar      = [];         % no default waitbar handle
    defaultDilate       = 2;          % number of pixels to dilate/erode pattern for trials
    
    addRequired(inp,'vidObj');
    addRequired(inp,'pattern');
    addOptional(inp,'inicoor', defaultInicoor);
    addOptional(inp,'range', defaultRange, @(r) (numel(r)==1 || numel(r)==2));
    addParameter(inp,'review', defaultReview, @isnumeric);
    addParameter(inp,'robustness', defaultRobustness, @isnumeric);
    addParameter(inp,'quality', defaultImageQuality, @isnumeric);
    addParameter(inp,'wideField', defaultWideField, @islogical);
    addParameter(inp,'buffer', defaultBuffer, @(x) ( ~isnan(x) && x > 0) );
    addParameter(inp,'waitbar', defaultWaitbar, @isgraphics);
    addParameter(inp,'dilate', defaultDilate, @(x) (isnumeric(x) && (numel(x) == 1 || numel(x)==2)) );
end

parse(inp, vidObj, pipette, varargin{:} );

defaultStrongRobust = min(0.80, inp.Results.robustness);       % minimal-robustness requirement; 0.8 at most

vidObj  = inp.Results.vidObj;
pipette = double(inp.Results.pattern);
if numel(inp.Results.range) == 2;       % two inputs; an interval
    range  = inp.Results.range;
    single = false;
elseif numel(inp.Results.range) == 1;   % only one input number
    if inp.Results.range == -1;         % whole range
        range  = [1, vidObj.Frames];
        single = false;
    else                                % single frame
        range = [ inp.Results.range, inp.Results.range ];
        single = true;
    end
end
framesToPass = range(2)-range(1)+1;     % total numbers of frames to process in this run
inicoor = [ inp.Results.inicoor(2), inp.Results.inicoor(1) ];   % initial pattern coordinates
review  = round(inp.Results.review);
robust  = [ defaultStrongRobust, inp.Results.robustness, (1+inp.Results.robustness)/2 ];    % robust(1) most severe -> robust(3) routine checking
quality = [ inp.Results.quality, (1+inp.Results.quality)/2 ];                               % quality(1) contrast problems threshold -> quality(2) routine checking
wideField = inp.Results.wideField;      % (bool); search the whole frame or just subfield
buffer  = inp.Results.buffer;
warnSev = [ 1, 1, 1 ];  % frame the last warning was issued (severity 1,2,3)
lastWF  = 1;            % frame the last wide field (i.e. full frame) search was performed
% if no WB was passed in and the interval is short, do not generate WB
if isempty(inp.Results.waitbar) && framesToPass < wbThresh;
    tbSwitch = false;
else
    tbSwitch = true;
    htrackbar = inp.Results.waitbar;
    wbStep = ceil(framesToPass/100);      % redraw after 1 %
end;
if numel(inp.Results.dilate)==1
    dilate=[inp.Results.dilate, inp.Results.dilate];    %dilate and erode the same ammount
else
    dilate=[inp.Results.dilate];    % two numbers were passed otherwise
end
% ======================================================================

%% ==== Set up computation variables ====
% sets OUT variables and temporary variables
[contrast,~] = vidObj.getContrast(range(1),range(2));    % returns values of contrast for the video (lazy-copy)

% mask to get values of neighbouring pixels
mask = [ [-1,-1]; [-1,0]; [-1,1]; [0,-1]; [0,0]; [0,1]; [1,-1]; [1,0]; [1,1] ];

pipDim = [size(pipette,1),size(pipette,2)]; % pipette dimensions [height,width]
% [ number of lines = vertical coor, nuber of cols = horizontal coor ]

frameDim = [vidObj.Height,vidObj.Width];                % frame dimensions from the video
frame = vidObj.readFrame(range(1));                     % start at time zero, if input is the first frame
% 'score' variable represents the score/coefficient of cross-correlation matching;
% returned for the currently processed frame, better not to preallocate right now.

if ~wideField && inicoor(1) ~= -1;  % inicoor input available
    box = [floor(inicoor - pipDim); ceil(inicoor + 2*pipDim - 1)];    % set a search box around initial guess
else
    box = [ 1, 1; frameDim ];   % search the whole field (the whole video frame) otherwise
end;

position = zeros(range(2)-range(1)+1,2); % preallocate; the position of the pipette at every timeframe
scores = zeros(size(position,1),1);      % the match metric of the pattern for each timeframe
badFrames = false(size(position,1),1);   % list of frames where detection is marked as failed
frames = 1;     % framecounter
failures = 0;   % failed detections counter
choice = 'report';  % switch for warning dialogues

% waitbar
if tbSwitch     % do use WB
    if ~isempty(htrackbar)
        wereTracked = htrackbar.UserData.wereTracked;   % get the number of finished frames
        htrackbar.UserData.pipmsg = strjoin({'Tracking pipette'});
        wbmsg = strjoin({htrackbar.UserData.intmsg,char(10),htrackbar.UserData.pipmsg});
        waitbar(0,htrackbar,wbmsg);
    else
        wereTracked = 0;
        htrackbar = waitbar(0,'Tracking bead','Name','Standalone pipette tracking');
        htrackbar.UserData.intmsg = 'No ongoing tracking provided';
        htrackbar.UserData.killTrack = false;
        htrackbar.UserData.toBeTracked = framesToPass;
    end
end

%% ==== Cycle thorough the frames and search the pattern ====
% analyse the interval of frames defined by 'range' parameter
while( (vidObj.CurrentFrame <= vidObj.Frames) && (frames <= framesToPass) )  % while there's another frame to read and range continues
    
%% ====  INFO SECTION  ====
% If not cancelled, update progress bar
    if tbSwitch
        if htrackbar.UserData.killTrack;
            cleanBreak(true);   % killed by user
            return; 
        end;        
        
        % update WB every wbStep frames
        % the WB redraw is costly; if the detection is stable, minimal
        % redraws are necessary;
        % TODO: the same step accross all processed intervals
        if ~mod(frames-1,wbStep)
            trackedRatio = (wereTracked + frames)/htrackbar.UserData.toBeTracked;
            htrackbar.UserData.pipmsg = strjoin({'Tracking pipette',char(10),'processing frame',strcat(num2str(frames),'/',num2str(framesToPass)),...
                char(10),'of the current tracking interval.',char(10),'Finished',...
                num2str(round(trackedRatio*100)),'% of total.'});
            wbmsg = strjoin({htrackbar.UserData.intmsg,char(10),htrackbar.UserData.pipmsg});
            waitbar(trackedRatio,htrackbar,wbmsg);
        end
    end
    
%% ====  TRACKING SECTION  ====
% Try to match the pipette tip pattern in the restricted (or, in minoriny
% of cases unrestricted) section of the video frame

    thisFrame = range(1)-1+frames;
    box = [ max(box(1,1),1), max(box(1,2),1); min(box(2,1),frameDim(1)), min(box(2,2), frameDim(2)) ];  % the restricted area to search for optimal match
    subframe = double(frame.cdata( box(1,1):box(2,1), box(1,2):box(2,2) ));   % the image (matrix) of the restricted area (box)
    
    % check if the presumed pattern is not out of field => failed tracking
    % (i.e. the restricted area is smaller than the pattern)
    if (any(size(subframe) < pipDim )) 
        cleanBreak(false);
        warndlg(strjoin({'At frame', num2str(thisFrame), 'position of the detected pattern upper left anchor is',...
            strcat('[',num2str(round(index(2))),',',num2str(round(index(1))),']'),'too near to the edge of the field.',...
            'The pipette left the field or the tracking must have failed in a few preceding frames.',...
            'The interval will be excluded from the tracking.'}),...
            'Pipette detection failure', 'replace');
        return;
    end
    
    score = normxcorr2( pipette, subframe );    % compute normalized cross correlation, 2D; note returns with padding
    score = score( pipDim(1):end - pipDim(1) + 1, pipDim(2):end - pipDim(2) + 1);   % clip for only unpadded correlations
    % here score(1,1) is identical pixel to the pixel denoted by numbers in box(1,1)
    
    % check the quality of contrast over 'review' window to determine further refinements
    contrastTest = mean(contrast(max(thisFrame-review,range(1)):thisFrame));   
    
    [maxscore, oneindex] = max(score(:));
    [index(1),index(2)] = ind2sub(size(score),oneindex);
    
    % treat unsucessful searches, 5 failure grace period allowed; old 
    % position value is copied for the next round
    if( isOut() );      % the pipette tip is outside the image
        if (~single); wideFieldSearch(2); end;          % attempt full field search correction
        if( isOut() );
            sortScore = sort(score(:),'descend');
            tmpScore = [0,0];
            for ss = sortScore'                         % find the strongest response in the proper field 
                [tmpScore(1),tmpScore(2)] = find(score==ss,1);
                if isOut(tmpScore); continue;
                else
                    index = tmpScore;
                    maxscore = score(index(1),index(2));
                    break; 
                end;
            end;
        end;
        
        % if the pipette is still outside the field; log fail and increment
        % the failcounter; if exceeded the fail-thresh, abort
        if( isOut() )
            failures = failures + 1;    % increment failure and issue warning
            if (failures < buffer);
                warning(strjoin({'At frame %d, detected optimal position is [%d,%d], out of bounds.',...
                'Corrective measures failed.\n',...
                'Consecutive detection failures: %d'}), thisFrame,index(2),index(1),failures);
                position(frames,:) = lastPosition();    % copy old position
                frames = frames + 1;                    % increment frame counter, to advance
                scores(frames,:)   = 0;
                continue;
            else
                cleanBreak(false);
                warndlg(strjoin({num2str(buffer), 'consecutive frame failures, detection failed at frame',...
                    [num2str(thisFrame),'.'],'The interval will be excluded from the results.'}),...
                    'Pipette detection failure','replace');
                return;
            end;
        end
    end;
    
    % calculate the maximum using least squares -- interpolation by
    % elliptic paraboloid over 9 pixels near the maximum
    LSQmat = zeros(9,6);    % LSQ matrix (gridpoints)
    LSQval = zeros(9,1);    % LSQ data values
    
    for m = 1:9
        ind = index + mask(m,:);
        LSQmat(m,:) = [ ind(1)^2, ind(2)^2, ind(1)*ind(2), ind(1), ind(2), 1 ];
        LSQval(m) = score(ind(1),ind(2));
    end
    
    failures = 0;   % reset failcounter after successful detection
    PSQ = lscov(LSQmat,LSQval); % get optimal parameters of the fit by least squares
    
    % get coordinates of the minimum of the optimal paraboloid fit
    X = -(PSQ(5) - 0.5*PSQ(3)/PSQ(1)*PSQ(4)) / (2*PSQ(2) - 0.5*PSQ(3)^2/PSQ(1));
    Y = 0.5*(-PSQ(4) - PSQ(3)*X)/PSQ(1);
    
    XYvec = [ Y^2, X^2, Y*X, Y, X, 1 ];
    maxscore = XYvec * PSQ; % calculate the max score of the fitted paraboloid
        
    pipPosition =  [X + box(1,2) - 1, Y + box(1,1) - 1];    % global coordinates of pipette tip position
    %[ horizontal coor, vertical coor ]
    
    index = [ pipPosition(2), pipPosition(1) ];   % [ row, col ] coordinates
    
    position(frames,:) = index;                   % save the pipette position
    scores(frames,:) = maxscore;                  % save the score (corr coeff)
    
    %% =================== test quality of detection ======================
    % calculates contrast and correlation metrics over review interval; the
    % averaging allows tolerance to noise/outliers
    if (range(2)-range(1) > review && ~single)  % if analyses enough frames
        metricTest = mean(scores(max(frames-review,1):frames,:));
        
        % metric test, mild metric underperformance, repeat test
        % occassionally, this is a routine testing
        if( metricTest < robust(3) && metricTest > robust(2) || contrastTest < quality(1) )...
          && frames-lastWF >= routineWF;  % minor drop in xcorr or contrast; tested more than 5 frames ago
            [~] = wideFieldSearch(3);     % returns true if detection improved; rearch the whole field; metrics are relaxed, if no improvement is returned
            lastWF = frames;
        end;
                
        % these methods fire up when problems occur; these are search in
        % the fill field and search using dilated/eroded pipette pattern
        if( metricTest <= robust(2) && lastWF ~= frames)       % major drop in xcorr metric and no WF this turn
            wideFieldSearch(2);
            lastWF = frames;
            if metricTest <= robust(2);     % metric is still too poor
                dilatedPatternSearch(dilate);   % uses dilated/eroded pattern from the initial frame to try to detect
                if metricTest <= robust(1)  % the xcorr is failing;
                    badFrames(frames,:) = true;     % log a bad frame
                    if strcmp(choice,'report') && frames-warnSev(1) >= 10;
                    choice = questdlg(strjoin({'The frame',num2str(thisFrame),'in the interval missed the quality requirements.',...
                        'The metric reads',num2str(round(metricTest,3)),'below threshold',num2str(round(robust(1),3)),...
                        'It is likely more problems will follow.',...
                        'Tracking procedure attempted corrective measures without success.',...
                        'Final report will illustrate, which points were problematic.',...
                        'Would You like to continue with the analysis? You can continue (without reports),',...
                        'with reports, or cancel.'}),'Low quality recognition','continue','report','cancel','continue');
                    warnSev(1) = frames;
                    if strcmp(choice,'cancel')
                        warning('Pipette tracking in interval (%d,%d) was canceled by user at frame %d after pattern correlation dropped to %.3f.',...
                            range(1),range(2), thisFrame, round(metricTest,3));
                        return;
                    end
                    end
                elseif metricTest <= robust(2) && frames-warnSev(2) >= 10;
                    warning(strjoin({'At frame %d, the pipette detection experiences severe uncertainty,',...
                        'but still remains above the minimum threshold.',...
                        'Corrective measures were not sufficient.',...
                        'The metric is %.3f above the minimum threshold %.3f '}), thisFrame, metricTest, robust(1));
                    warnSev(2) = frames;
                end
            end
        end        
    end
        
    % test if the pipette tip did not make too large leap (no more than 5
    % pixels is allowed by default);    
    %TODO: let user to modify this parameter
    if (~single)         
        dist = norm( index - lastPosition(true) );
        if dist > maxSkip; [~] = wideFieldSearch(0); end;   % verify by WF (with suppressed reports)
        dist = norm( index - lastPosition(true) );
        if dist > maxSkip;  % if WF did not improve the large skip
            badFrames(frames,:) = true;
            if frames - warnSev(1) >= 10;
                warning(strjoin({'At frame %d a suspiciously large displacement of pipette occured, %.1f pixels.',...
                'Anything above %d pixels is considered suspicious. Frame was logged as a bad frame.'}),...
                thisFrame,dist,maxSkip);
                warnSev(1) = frames;
            end;
        end
        if mod(thisFrame,100)==0; disp(strjoin({'Pipette tracking: ',num2str(thisFrame),'/',num2str(range(2))})); end;        
        frame = vidObj.readFrame();        % read the next frame as grayscale
        box = [floor(index - pipDim); ceil(index + 2*pipDim - 1)];     % update the bounding box for the next search
    end
    frames = frames + 1;               % increment the counter
        
end;    % end for the while cycle of the interval
%% ==== after-search clean-up ====
vidObj.readFrame(range(1));
if(tbSwitch)
    htrackbar.UserData.wereTracked = wereTracked + framesToPass;  % add frames that were passed
end;

%% ===== Support nested functions =====

    % tries to search for the pipette in the full field; if better match is
    % found, position is ammended and 'metricTest' recalculated; otherwise,
    % command line warning is issued and minor-threshold sensitivity
    % decreased
    function [improved] = wideFieldSearch(S)

        [wfPos,wfMet] = TrackPipette( vidObj, pipette, lastPosition(), thisFrame,'wideField',true);
        if wfMet > maxscore;    % better match was found in the full field
            position(frames,:) = wfPos;
            index              = wfPos;
            scores(frames,:)   = wfMet;
            maxscore           = wfMet;
            metricTest = mean(scores(max(frames-review,1):frames,:));   % try if new metric passes the test
            improved = true;
            if S==3;robust(3) = min( robust(3)+0.005, (1+robust(2))/2 ); end;   % if the method improves results (and was desensitized before), increase sensitivity again
        elseif S~=0                      % there is no improvement; S==0 means no reports, no modifications
            if frames-warnSev(S) >= 10;  % display warning at most every 10 frames
                warning(strjoin({'At frame %d, the pipette correlation metric dropped to %.3f.',...
                'The contrast metric dropped to %.3f.'}), range(1)-1+frames, metricTest, contrastTest );
            end;    
            if S==3;robust(3) = max( robust(3)-0.005, robust(2) );end;  % desensitize the control, if no results are produced, call less often
            warnSev(S) = frames;
            improved = false;
        else
            improved = false;
        end;
    end
    
    % in case of low metric results, the program tries to increase match
    % by selecting larger pattern than initially. The pattern is 
    % dilated/eroded by C-pixels in every direction.
    % C(1), erosion; C(2), dilatation
    function [improved] = dilatedPatternSearch(C)
        % tries to localte the pattern in interval's first frame. If
        % detection is reliable enough, continues with the procedure. The
        % function is not used again, if reliable pattern location can't be
        % established in the frame.
        
        if numel(C) ~= 2 || ...     % not an interval input
           maxscore > robust(2)     % single point detection strength is good (metric test is based on averaging) 
            return;
        end
        
        improved = false;
        persistent confirmed;           % an initial test says, if method can be used in interval or not
        if ~isempty(confirmed);
            if ~confirmed; return; end; % if pipette is not confirmed (in 1st frame), return
        end
        if C(1)==0 && C(2)==0;  % case of no erosion no dilatation
            confirmed=false;
            return;
        end
        persistent wfPos;
        persistent wfMet;
        if isempty(wfMet)
            [wfPos,wfMet,~] = TrackPipette( vidObj, pipette, [inicoor(2),inicoor(1)], range(1),'wideField',true);   % search the original pattern in the first wide field frame
        end;
        if wfMet < dilatedRobust;    % if pattern at interval's init. frame matches orig. pattern less than dilatedRobust, abort
            improved = false;
            confirmed = false;
            warndlg(strjoin({'Method attempts to improve detection by trying to dilate the',...
                'pipette pattern. It was, however, impossible to precisely localize the pattern at the',...
                'first frame, frame',num2str(range(1)),', of the analyzed interval. With correlation',...
                num2str(wfMet),'not meeting the required strength of',num2str(dilatedRobust),...
                'Program will continue without the feature. You can try to resolve the problem by',...
                ' choosing another pattern.'}));
            return;
        end;
        

        persistent dilPipette;   % dilated pipette pattern array
        persistent wfShift;
        if isempty(dilPipette)
            firstFrame = vidObj.readFrame(range(1));    % read the first frame of the interval
            wfShift = wfPos - round(wfPos); % save offset of the array from max. likely location
            wfPos = round(wfPos);           % get rounded position
            dilPipette = struct('frame',[]);% create empty structure
            for V=-C(1):1:C(2)
                if (V>0 && (wfPos(1)-V < 1) || (wfPos(1)-1+V+pipDim(1) > frameDim(1)) ||...
                           (wfPos(2)-V < 1) || (wfPos(2)-1+V+pipDim(2) > frameDim(2)) )   % if new pipette is out of filed
                    C(2)=V-1;   % stop pattern generation
                    break;
                end                       
                dilFrame = [ wfPos(1)-V, wfPos(1)-1+V+pipDim(1); ...
                             wfPos(2)-V, wfPos(2)-1+V+pipDim(2)];
                dilPipette(V+C(1)+1).frame = ...
                    double(firstFrame.cdata( dilFrame(1,1):dilFrame(1,2), dilFrame(2,1):dilFrame(2,2),: ));    % pipette pattern dilated by C pixels on each side
            end
        end

        dpPos=zeros(C(2)+C(1)+1,2);   % preallocate positions...
        dpMet=zeros(C(2)+C(1)+1,1);   % ... and metrics
        for V=-C(1):1:C(2)    % test search with dilated and eroded patterns
            I = V+C(1)+1;  % indexing
            if V==0; continue; end % skip original-size shifted pattern
            [dpPos(I,:),dpMet(I),~] = ... % run the bloody expensive searches
                TrackPipette( vidObj, dilPipette(I).frame, lastPosition()-[V,V], thisFrame);  % search dilated pipette in the box
        end
        
        [metMax,metInd] = max(dpMet);   % get the value and index of maximal match
        
        if metMax > maxscore     % improvement
            warning(strjoin({'At frame %d, the corrective measure increased metric from the value',...
                '%.6f to %.6f with the pattern changed by %d pixels'}),...
                thisFrame, maxscore, metMax, metInd-C(1)-1);
            index              = dpPos(metInd,:) + [metInd-C(1)-1,metInd-C(1)-1] + wfShift;
            position(frames,:) = index;
            scores(frames,:)   = metMax;
            maxscore           = metMax;
            metricTest = mean(scores(max(frames-review,1):frames,:));   % try if new metric passes the test
            improved = true;
            
        else
            if frames-warnSev(2) >= 10;  % display warning at most every 10 frames
                warning(strjoin({'At frame %d, the pipette correlation metric dropped to %.3f.',...
                'The lowest threshold value is %.3f.'}), thisFrame, metricTest, robust(1) );
                warnSev(2) = frames;
            end;    
            improved = false;
        end;
    end

    % returns last coordinates considered correct (in [X,Y], not [row,col])
    % if function is passed 'true', returns vars as [row,col]
    function [LP] = lastPosition(varargin)
        if nargin==1
            if varargin{1} == true;
                lp = lastPosition();
                LP = [lp(2),lp(1)];
            end
            return;
        end
        
        if frames > 1
            LP = [position(frames-1,2), position(frames-1,1)];
        else
            LP = [inicoor(2),inicoor(1)];
        end
    end

    % tests if result is invalid (outside of relevant area)
    function [out] = isOut(varargin)
        out = false;
        if nargin == 0;
            out = (index(1) <= 1 || index(1) >= size(score,1) || index(2) <=1 || index(2) >= size(score,2));
        elseif nargin == 1
            pix = varargin{1};
            if numel(pix) ~= 2; 
                warning('Incorrect input in ''isOut'' function. Input must be a pair of indices, [row,col]');
                return;
            end
            out = (pix(1) <= 1 || pix(1) >= size(score,1) || pix(2) <=1 || pix(2) >= size(score,2));
        else
            warning('Incorrect input in ''isIn'' function. Input must be a pair of indices, [row,col]');
        end
    end

    % facilitate orderly exit, if detection goes wrong
    function [] = cleanBreak(user)        
        position(frames:end,:)  = [];                    % crop zeros...
        scores(frames:end,:)    = [];
        badFrames(frames:end,:) = [];
        vidObj.readFrame(range(1));                    % reset the first frame;
        if ~user; 
            htrackbar.UserData.failure = true;          % report tracking failed
            htrackbar.UserData.wereTracked = wereTracked + framesToPass;    % report the interval as parsed
        else
            htrackbar.UserData.wereTracked = wereTracked;  % cancelled tracking, reset the counter 
            htrackbar.UserData.killTrack = true;           % stop tracking 
        end;
    end

   
end

