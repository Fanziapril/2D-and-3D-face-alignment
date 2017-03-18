local utils = {}

function utils.getTransform(center, scale, res)
	local h = 200*scale
	local t = torch.eye(3)
	
	-- Scale
	t[1][1] = res/h
	t[2][2] = res/h
	
	-- Translate
	t[1][3] = res*(-center[1]/h+0.5)
	t[2][3] = res*(-center[2]/h+0.5)

	return t
end

-- Transform the coordinates from the original image space to the cropped one
function utils.transform(pt, center, scale, res, invert)
    -- Define the transformation matrix
    local pt_new = torch.ones(3)
    pt_new[1], pt_new[2] = pt[1], pt[2]
    local t = utils.getTransform(center, scale, res)
    if invert then
        t = torch.inverse(t)
    end
    local new_point = (t*pt_new):sub(1,2):int()
    return new_point
end

-- Crop based on the image center & scale
function utils.crop(img, center, scale, res)
    local l1 = utils.transform({1,1}, center, scale, res, true)
    local l2 = utils.transform({res,res}, center, scale, res, true)

    local pad = math.floor(torch.norm((l1 - l2):float())/2 - (l2[1]-l1[1])/2)
    
    if img:nDimension() < 3 then
      img = torch.repeatTensor(img,3,1,1)
    end

    local newDim = torch.IntTensor({img:size(1), l2[2] - l1[2], l2[1] - l1[1]})
    local newImg = torch.zeros(newDim[1],newDim[2],newDim[3])
    local height, width = img:size(2), img:size(3)

    local newX = torch.Tensor({math.max(1, -l1[1]+1), math.min(l2[1], width) - l1[1]})
    local newY = torch.Tensor({math.max(1, -l1[2]+1), math.min(l2[2], height) - l1[2]})
    local oldX = torch.Tensor({math.max(1, l1[1]+1), math.min(l2[1], width)})
    local oldY = torch.Tensor({math.max(1, l1[2]+1), math.min(l2[2], height)})

    newImg:sub(1,newDim[1],newY[1],newY[2],newX[1],newX[2]):copy(img:sub(1,newDim[1],oldY[1],oldY[2],oldX[1],oldX[2]))

    newImg = image.scale(newImg,res,res)
    return newImg
end

function utils.getPreds(heatmaps, center, scale)
    if heatmaps:nDimension() == 3 then heatmaps = heatmaps:view(1, unpack(heatmaps:size():totable())) end

    -- Get locations of maximum activations
    local max, idx = torch.max(heatmaps:view(heatmaps:size(1), heatmaps:size(2), heatmaps:size(3) * heatmaps:size(4)), 3)
    local preds = torch.repeatTensor(idx, 1, 1, 2):float()
    preds[{{}, {}, 1}]:apply(function(x) return (x - 1) % heatmaps:size(4) + 1 end)
    preds[{{}, {}, 2}]:add(-1):div(heatmaps:size(3)):floor():add(1)

    for i = 1,preds:size(1) do        
        for j = 1,preds:size(2) do
            local hm = heatmaps[{i,j,{}}]
            local pX, pY = preds[{i,j,1}], preds[{i,j,2}]
            if pX > 1 and pX < 64 and pY > 1 and pY < 64 then
                local diff = torch.FloatTensor({hm[pY][pX+1]-hm[pY][pX-1], hm[pY+1][pX]-hm[pY-1][pX]})
                preds[i][j]:add(diff:sign():mul(.25))
            end
        end
    end
    preds:add(-0.5)

    -- Get the coordinates in the original space
    local preds_orig = torch.zeros(preds:size())
    for i = 1, heatmaps:size(1) do
        for j = 1, heatmaps:size(2) do
            preds_orig[i][j] = utils.transform(preds[i][j],center,scale,heatmaps:size(3),true)
        end
    end
    return preds, preds_orig
end

function utils.shuffleLR(opts, x)
    local dim
    if x:nDimension() == 4 then
        dim = 2
    else
        assert(x:nDimension() == 3)
        dim = 1
    end

    local matched_parts = {
			{1,17},   {2,16},   {3,15},
            {4,14}, {5,13}, {6,12}, {7,11}, {8,10},
            {18,27},{19,26},{20,25},{21,24},{22,23},
            {37,46},{38,45},{39,44},{40,43},
            {42,47},{41,48},
            {32,36},{33,35},
			{51,53},{50,54},{49,55},{62,64},{61,65},{68,66},{60,56},
            {59,57}
		}

    for i = 1,#matched_parts do
        local idx1, idx2 = unpack(matched_parts[i])
        local tmp = x:narrow(dim, idx1, 1):clone()
        x:narrow(dim, idx1, 1):copy(x:narrow(dim, idx2, 1))
        x:narrow(dim, idx2, 1):copy(tmp)
    end

    return x
end

function utils.flip(x)
    local y = torch.FloatTensor(x:size())
    for i = 1, x:size(1) do
        image.hflip(y[i], x[i]:float())
    end
    return y:typeAs(x)
end


function utils.calcDistance(predictions,groundTruth)
  local n = predictions:size()[1]
  gnds = torch.Tensor(n,68,2)
  for i=1,n do
    gnds[{{i},{},{}}] = groundTruth[i].points
  end

  local dists = torch.Tensor(predictions:size(2),predictions:size(1))
  -- Calculate L2
	for i = 1,predictions:size(1) do
		for j = 1,predictions:size(2) do
			if gnds[i][j][1] > 1 and gnds[i][j][2] > 1 then
				dists[j][i] = torch.dist(gnds[i][j],predictions[i][j])/groundTruth[i].headSize
			else
				dists[j][i] = -1
			end
		end
	end

  return dists
end

--http://stackoverflow.com/questions/640642/how-do-you-copy-a-lua-table-by-value
function table.copy(t)
   if t == nil then
      return {}
   end
   local u = { }
   for k, v in pairs(t) do u[k] = v end
   return setmetatable(u, getmetatable(t))
end

-- originally created in torch dp package, by nicholas leonard
function torch.swapaxes(tensor, new_axes)

   -- new_axes : A table that give new axes of tensor, 
   -- example: to swap axes 2 and 3 in 3D tensor of original axes = {1,2,3}, 
   -- then new_axes={1,3,2}
 
   local sorted_axes = table.copy(new_axes)
   table.sort(sorted_axes)
   
   for k, v in ipairs(sorted_axes) do
      assert(k == v, 'Error: new_axes does not contain all the new axis values')
   end       

   -- tracker is used to track if a dim in new_axes has been swapped
   local tracker = torch.zeros(#new_axes)   
   local new_tensor = tensor

   -- set off a chain swapping of a group of intraconnected dimensions
   _chain_swap = function(idx)
      -- if the new_axes[idx] has not been swapped yet
      if tracker[new_axes[idx]] ~= 1 then
         tracker[idx] = 1
         new_tensor = new_tensor:transpose(idx, new_axes[idx])
         return _chain_swap(new_axes[idx])
      else
         return new_tensor
      end    
   end
   
   for idx = 1, #new_axes do
      if idx ~= new_axes[idx] and tracker[idx] ~= 1 then
         new_tensor = _chain_swap(idx)
      end
   end
   
   return new_tensor
end

function utils.bounding_box(iterable)
    local mins = torch.min(iterable, 1):view(2)
    local maxs = torch.max(iterable, 1):view(2)

	local center = torch.FloatTensor{maxs[1]-(maxs[1]-mins[1])/2, maxs[2]-(maxs[2]-mins[2])/2}
    
	return center, (maxs[1]-mins[1]+maxs[2]-mins[2])/190 --center and scale
end

local function subrange(t, first, last)
  local sub = {}
  for i=first,last do
    sub[#sub + 1] = t[i]
  end
  return sub
end

-- Requires gnuplot
function utils.plot(surface, points, size)
	if points:nDimension()~=2 then
		points = points:view(points:size(2),2)
	end
	
    gnuplot.figure(1)
    gnuplot.raw("set size ratio -1")
	gnuplot.raw("set xrange [0:"..size[1].."]")
	gnuplot.raw("set yrange [0:"..size[2].."]")
    gnuplot.raw("unset key; unset tics; unset border;")
	gnuplot.raw("set multiplot layout 1,1 margins 0.05,0.95,.1,.99 spacing 0,0")
    local extname = paths.extname(surface)    
gnuplot.raw("plot '"..surface.."' binary filetype="..extname.." with rgbimage")  

	gnuplot.raw(" set yrange ["..size[2]..":0] ") 
	
	local x = points[{{},{1}}]:contiguous():view(68)
	local y = points[{{},{2}}]:contiguous():view(68)

	gnuplot.plot(x, y, '+')
	gnuplot.raw("unset multiplot")
end

function utils.readpts(file_path)
	lines = {}
	for line in io.lines(file_path) do
		lines[#lines+1] = line
	end
	
	local num_points = tonumber(lines[2]:split(' ')[2])
	local pts = torch.Tensor(num_points,2)
	for i = 4,3+num_points do
		pts[{{i-3},{}}] = torch.Tensor{lines[i]:split(' ')[1],lines[i]:split(' ')[2]}
	end
	
	return pts
end

function utils.getFileList(opts)
    print('Scanning directory for data...')
    local data_path = opts.path
    local filesList = {}
    for f in paths.files(data_path, function (file) return file:find('.jpg') or file:find('.png') end) do
        -- Check if we have .t7 or .pts file
        local pts = nil
        if paths.filep(data_path..f:sub(1,#f-4)..'.t7') then
            pts = torch.load(data_path..f:sub(1,#f-4)..'.t7')
        end
        if paths.filep(data_path..f:sub(1,#f-4)..'.pts') then
           pts = utils.readpts(data_path..f:sub(1,#f-4)..'.pts')
        end
        if pts ~= nil then
            local data_pts = {}
            local center, scale = utils.bounding_box(pts)
            data_pts.image = data_path..f
            data_pts.scale = scale
            data_pts.center = center
            data_pts.points = pts

            filesList[#filesList+1] = data_pts
        end
    end
    print('Found '..#filesList..' images')
    return filesList
end

return utils