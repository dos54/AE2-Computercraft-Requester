--- @class Queue Data structure following FIFO (First In First Out)
--- @field items table<number, any> stores items in the queue
--- @field head number Points to the head of the queue
--- @field tail number Points to the tail of the queue
--- @field maxSize number|nil The maximun size of the queue (optional)
local Queue = {}

--- Creates a new Queue object
--- @param maxSize integer|nil (optional) the maximum size of the queue. If nil, the queue has no size limit.
--- @return Queue The new Queue object.
function Queue:new(maxSize)
    local obj = {
        items = {},
        head = 1,
        tail = 0,
        maxSize = maxSize or nil
    }
    setmetatable(obj, self)
    self.__index = self
    return obj
end

function Queue:clear()
    self.items = {}
    self.head = 1
    self.tail = 0
end

function Queue:trim()
    if Queue:isEmpty() then
        Queue:clear()
    else
        error("Unable to trim queue; items still in queue.")
    end
end

function Queue:isEmpty()
    return self.head > self.tail
end

function Queue:contains(item)
    for index, value in ipairs(self.items) do
        if item == value then
            return true
        end
    end
    return false
end

--- Add an item (value) to the back of the queue.
--- @param value any Value to be added to the queue
function Queue:enqueue(value)
    if self.maxSize and self:size() >= self.maxSize then
        error("Queue is full. Cannot enqueue.")
    end
    self.tail = self.tail + 1
    self.items[self.tail] = value
end

function Queue:dequeue()
    if self:isEmpty() then
        error("Queue is empty. Cannot dequeue.")
    end

    local value = self.items[self.head]
    self.items[self.head] = nil
    self.head = self.head + 1
    return value
end

function Queue:size()
    return self.tail - self.head + 1
end

---Ensure that the queue has at least a specified capacity
---@param capacity integer
---@return integer
function Queue:ensureCapacity(capacity)
    if self.maxSize < capacity then
        self.maxSize = capacity
    end
    return self.maxSize
end

---Return the object at the beginning of the queue without removing it.
---@return any
function Queue:peek()
    if self:isEmpty() then
        return nil
    end

    return self.items[self.head]
end

---Copy the queue into a new array at index arrayIndex
---@param array table
---@param arrayIndex integer
function Queue:copyTo(array, arrayIndex)
    if array == nil then
        error("Please provide a valid array.")
    end

    if type(arrayIndex) ~= "number" or arrayIndex < 1 then
        error("The arrayIndex must be a positive integer.")
    end

    for i = 1, #self.items do
        array[arrayIndex + (i - 1)] = self.items[i]
    end
end

return Queue