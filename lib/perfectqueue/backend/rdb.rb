
module PerfectQueue


class RDBBackend < Backend
  def initialize(uri, table)
    require 'sequel'
    @uri = uri
    @table = table
    @db = Sequel.connect(@uri)
    #init_db(@uri.split('//',2)[0])
    connect {
      # connection test
    }
    @sql = <<SQL
SELECT id, timeout, data, created_at, resource
FROM `#{@table}`
LEFT JOIN (
  SELECT resource AS res,
         CASE WHEN resource IS NULL THEN 0 ELSE COUNT(1) END AS running
  FROM `#{@table}`
  WHERE timeout > ? AND created_at IS NOT NULL
  GROUP BY resource
) AS T ON resource = res
WHERE timeout <= ? AND (running IS NULL OR running < #{MAX_RESOURCE})
LIMIT #{MAX_SELECT_ROW}
SQL
  end

  def create_tables
    sql = ''
    sql << "CREATE TABLE IF NOT EXISTS `#{@table}` ("
    sql << "  id VARCHAR(256) NOT NULL,"
    sql << "  timeout INT NOT NULL,"
    sql << "  data BLOB NOT NULL,"
    sql << "  created_at INT,"
    sql << "  resource VARCHAR(256),"
    sql << "  PRIMARY KEY (id)"
    sql << ");"
    # TODO index
    connect {
      @db.run sql
    }
  end

  private
  def connect(&block)
    begin
      block.call
    ensure
      @db.disconnect
    end
  end

  public
  def list(&block)
    @db.fetch("SELECT id, timeout, data, created_at, resource FROM `#{@table}` WHERE created_at IS NOT NULL ORDER BY timeout ASC;") {|row|
      yield row[:id], row[:created_at], row[:data], row[:timeout], row[:resource]
    }
  end

  MAX_SELECT_ROW = 4
  MAX_RESOURCE = (ENV['PQ_MAX_RESOURCE'] || 4).to_i

  def acquire(timeout, now=Time.now.to_i)
    connect {
      @db.run "LOCK TABLES `#{@table}`, T WRITE;" rescue nil  # TODO mysql only
      begin
        while true
          rows = 0
          @db.fetch(@sql, now, now) {|row|

            unless row[:created_at]
              # finished/canceled task
              @db["DELETE FROM `#{@table}` WHERE id=?;", row[:id]].delete

            else
              n = @db["UPDATE `#{@table}` SET timeout=? WHERE id=? AND timeout=?;", timeout, row[:id], row[:timeout]].update
              if n > 0
                return row[:id], Task.new(row[:id], row[:created_at], row[:data], row[:resource])
              end
            end

            rows += 1
          }
          if rows < MAX_SELECT_ROW
            return nil
          end
        end
      ensure
        @db.run "UNLOCK TABLES T, `#{@table}`;" rescue nil  # TODO mysql only
      end
    }
  end

  def finish(id, delete_timeout=3600, now=Time.now.to_i)
    connect {
      n = @db["UPDATE `#{@table}` SET timeout=?, created_at=NULL, resource=NULL WHERE id=? AND created_at IS NOT NULL;", now+delete_timeout, id].update
      return n > 0
    }
  end

  def update(id, timeout)
    connect {
      n = @db["UPDATE `#{@table}` SET timeout=? WHERE id=? AND created_at IS NOT NULL;", timeout, id].update
      if n <= 0
        raise CanceledError, "Task id=#{id} is canceled."
      end
      return nil
    }
  end

  def cancel(id, delete_timeout=3600, now=Time.now.to_i)
    finish(id, delete_timeout, now)
  end

  def submit(id, data, time=Time.now.to_i, resource=nil)
    connect {
      begin
        n = @db["INSERT INTO `#{@table}` (id, timeout, data, created_at, resource) VALUES (?, ?, ?, ?, ?);", id, time, data, time, resource].insert
        return true
      rescue Sequel::DatabaseError
        return nil
      end
    }
  end
end


end

