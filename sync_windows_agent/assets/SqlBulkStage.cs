using System;
using System.Collections;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace SqlSync
{
    public static class BulkStageLoader
    {
        public static int Load(string requestPath)
        {
            var serializer = new JavaScriptSerializer
            {
                MaxJsonLength = int.MaxValue,
                RecursionLimit = 100
            };
            var request = AsDictionary(
                serializer.DeserializeObject(File.ReadAllText(requestPath, Encoding.UTF8)));
            var rows = AsList(request["rows"]);
            if (rows.Count == 0)
            {
                return 0;
            }
            var columns = AsList(request["columns"]);
            var table = new DataTable();
            var columnTypes = new string[columns.Count];
            for (var columnIndex = 0; columnIndex < columns.Count; columnIndex += 1)
            {
                var definition = AsDictionary(columns[columnIndex]);
                var name = Convert.ToString(definition["name"], CultureInfo.InvariantCulture);
                var sqlType = Convert.ToString(
                    definition["sqlType"], CultureInfo.InvariantCulture).Trim().ToLowerInvariant();
                columnTypes[columnIndex] = sqlType;
                var column = new DataColumn(name, DataColumnType(sqlType)) { AllowDBNull = true };
                table.Columns.Add(column);
            }
            foreach (var rawRow in rows)
            {
                var sourceRow = AsList(rawRow);
                if (sourceRow.Count != columns.Count)
                {
                    throw new InvalidDataException("Bulk stage row width does not match its column metadata.");
                }
                var values = new object[columns.Count];
                for (var columnIndex = 0; columnIndex < columns.Count; columnIndex += 1)
                {
                    values[columnIndex] = ConvertValue(sourceRow[columnIndex], columnTypes[columnIndex]);
                }
                table.Rows.Add(values);
            }

            var connectionBuilder = new SqlConnectionStringBuilder
            {
                DataSource = StringValue(request, "server"),
                InitialCatalog = StringValue(request, "database"),
                ConnectTimeout = IntValue(request, "connectTimeoutSeconds"),
                TrustServerCertificate = true,
                IntegratedSecurity = BoolValue(request, "useWindowsAuth")
            };
            if (!connectionBuilder.IntegratedSecurity)
            {
                connectionBuilder.UserID = StringValue(request, "user");
                connectionBuilder.Password = StringValue(request, "password");
            }
            using (var connection = new SqlConnection(connectionBuilder.ConnectionString))
            {
                connection.Open();
                using (var bulkCopy = new SqlBulkCopy(
                    connection,
                    SqlBulkCopyOptions.TableLock | SqlBulkCopyOptions.UseInternalTransaction,
                    null))
                {
                    bulkCopy.DestinationTableName = StringValue(request, "destinationTable");
                    bulkCopy.BatchSize = IntValue(request, "commitBatchRows");
                    bulkCopy.BulkCopyTimeout = IntValue(request, "commandTimeoutSeconds");
                    foreach (DataColumn column in table.Columns)
                    {
                        bulkCopy.ColumnMappings.Add(column.ColumnName, column.ColumnName);
                    }
                    bulkCopy.WriteToServer(table);
                }
            }
            return table.Rows.Count;
        }

        private static Type DataColumnType(string sqlType)
        {
            switch (sqlType)
            {
                case "bigint": return typeof(long);
                case "int": return typeof(int);
                case "smallint": return typeof(short);
                case "tinyint": return typeof(byte);
                case "bit": return typeof(bool);
                case "decimal":
                case "numeric":
                case "money":
                case "smallmoney": return typeof(decimal);
                case "float": return typeof(double);
                case "real": return typeof(float);
                case "binary":
                case "varbinary": return typeof(byte[]);
                case "uniqueidentifier": return typeof(Guid);
                case "date":
                case "datetime":
                case "smalldatetime":
                case "datetime2": return typeof(DateTime);
                case "datetimeoffset": return typeof(DateTimeOffset);
                case "time": return typeof(TimeSpan);
                default: return typeof(string);
            }
        }

        private static object ConvertValue(object value, string sqlType)
        {
            if (value == null)
            {
                return DBNull.Value;
            }
            var text = Convert.ToString(value, CultureInfo.InvariantCulture);
            switch (sqlType)
            {
                case "bigint": return long.Parse(text, CultureInfo.InvariantCulture);
                case "int": return int.Parse(text, CultureInfo.InvariantCulture);
                case "smallint": return short.Parse(text, CultureInfo.InvariantCulture);
                case "tinyint": return byte.Parse(text, CultureInfo.InvariantCulture);
                case "bit": return text == "1" || (text != "0" && bool.Parse(text));
                case "decimal":
                case "numeric":
                case "money":
                case "smallmoney":
                    return decimal.Parse(
                        text,
                        NumberStyles.Number | NumberStyles.AllowExponent,
                        CultureInfo.InvariantCulture);
                case "float": return double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
                case "real": return float.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
                case "binary":
                case "varbinary": return HexBytes(text);
                case "uniqueidentifier": return Guid.Parse(text);
                case "date":
                case "datetime":
                case "smalldatetime":
                case "datetime2":
                    return String.IsNullOrWhiteSpace(text)
                        ? (object)DBNull.Value
                        : DateTime.Parse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
                case "datetimeoffset":
                    return String.IsNullOrWhiteSpace(text)
                        ? (object)DBNull.Value
                        : DateTimeOffset.Parse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
                case "time":
                    return String.IsNullOrWhiteSpace(text)
                        ? (object)DBNull.Value
                        : TimeSpan.Parse(text, CultureInfo.InvariantCulture);
                default: return text;
            }
        }

        private static byte[] HexBytes(string value)
        {
            var hex = value.Trim();
            if (hex.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            {
                hex = hex.Substring(2);
            }
            if ((hex.Length % 2) != 0)
            {
                throw new InvalidDataException("Binary SQL value has an odd hexadecimal length.");
            }
            var bytes = new byte[hex.Length / 2];
            for (var index = 0; index < bytes.Length; index += 1)
            {
                bytes[index] = Convert.ToByte(hex.Substring(index * 2, 2), 16);
            }
            return bytes;
        }

        private static IDictionary<string, object> AsDictionary(object value)
        {
            var dictionary = value as IDictionary<string, object>;
            if (dictionary == null)
            {
                throw new InvalidDataException("Bulk stage request object is invalid.");
            }
            return dictionary;
        }

        private static IList AsList(object value)
        {
            var list = value as IList;
            if (list == null)
            {
                throw new InvalidDataException("Bulk stage request array is invalid.");
            }
            return list;
        }

        private static string StringValue(IDictionary<string, object> request, string name)
        {
            return Convert.ToString(request[name], CultureInfo.InvariantCulture);
        }

        private static int IntValue(IDictionary<string, object> request, string name)
        {
            return Convert.ToInt32(request[name], CultureInfo.InvariantCulture);
        }

        private static bool BoolValue(IDictionary<string, object> request, string name)
        {
            return Convert.ToBoolean(request[name], CultureInfo.InvariantCulture);
        }
    }
}
